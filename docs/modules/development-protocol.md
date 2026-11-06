# Module 9b: the development protocol, the debugger and the agent interface

Status: built, 2026-11-04, from the brief of the same day (the owner's
answers to the draft's six questions, kept at the end). Module 9 is three
builds: **9b (this)**, the protocol, its headless transport and clients,
the debugger's target side with stepping, sources to the project
directory, the agent interface (MCP and CLI) and the kernel items the
owner decided alongside; **9c**, the developer UI in Smalltalk in the
macOS shell (what it needs from here is listed under "What 9c needs");
**9d**, the transport to the phone. The owner's rule for the split holds:
Swift is the compiler and the bindings (and here the transport and the
clients, which are bindings to sockets and stdio); everything a developer
uses is Smalltalk.

New: `Sources/KajoDev/` (a library target: the protocol's JSON and request
checks, the Unix-socket transport `ProtocolServer`, the headless target
`DevTarget`, the client `ProtocolClient`, the project writer, the MCP
server, the CLI commands), `Sources/fuzz-protocol/` (`just fuzz protocol`),
`Sources/KajoVM/Processes/Debugging.swift` (primitives 155 to 158 and 162:
interrupts, the re-executed send, stepping, the Process list), the
protocol inbox in `Shell/ShellBridge.swift` with primitives 159 to 161 in
`Shell/ShellPrimitives.swift`, primitive 163 (obsolete classes freed) in
`ObjectModel/LiveClasses.swift`, the sealed-extension rule in
`ObjectModel/LiveMethods.swift`, the pc-to-source map in
`Loader/Assembler.swift` (`SourceMap`) and both compilers; in the kernel
`Json`, `JsonObject`, `DevProtocol`, `DevSession`, `Debugger`,
`DebugStop`, `DevelopmentTest`, and changes to 21 kernel classes (below);
in the shells, `protocol=<socket>` and the `debugstop` scenario
(`KajoShellCore`). Two ADRs: 0011 (the protocol) and 0012 (stepping),
both proposed. Tests: `Tests/KajoCompilerTests/DevProtocolTests.swift`
(the protocol, the debugger through it, the latency measurement),
`AgentInterfaceTests.swift` (MCP, the project round trip), the fixture
project `Tests/KajoCompilerTests/Fixtures/project/` (package `Sample`), and
`kernel/DevelopmentTest.class.st`.

## What it hides

- How a developer, a script or an agent reaches a running image: one
  protocol, one transport per target, a token, and who may do what.
- What the debugger is made of: an unhandled error, a step's end or a
  suspend becomes a stopped Process that waits with its stack intact and
  serves the debugger's commands itself; stepping is a rule at the poll,
  the interpreter's fast paths unchanged.
- Where sources go: the target answers every accepted change with the
  files of the session's package it touched, and the client writes them
  into the project directory; who made a method is in its metadata.
- What an agent sees (every request, as an MCP tool, with the target's
  events) and what it may never do (enforced in the target).

## 1. The protocol (ADR 0011)

### Form

One JSON object per line, both ways. A request:

```
{"v":1,"id":7,"kind":"method.compile","args":{"className":"Foo","source":"bar ^ 1","category":"x","side":null}}
```

`v` is 1, `id` a string (at most 256 bytes) or an integer, `kind` dotted
lower-camel words (at most 64 bytes), `args` an object of lower-camel names
(at most 32); nothing else. A reply echoes the id:
`{"v":1,"kind":"reply","conn":3,"id":7,"ok":true,"result":...}` or
`"ok":false,"error":"..."` (`conn` is the target's routing; clients ignore
it). Events have no id: 8b's stream as it was (`transcript`, `test.*`,
`run.*`) and the debugger's `process.stopped` (the Process, the reason
`error`, `step` or `suspended`, the error, the first 32 frames each with
its method, pc and the source range its pc is at) and `process.resumed`.
An error is a reply, never a dropped connection; the one exception is a
connection whose first request is not a valid `session.open`, which gets
its error reply and is closed.

### Requests are methods (`<devProtocol>`)

Every request is an instance method of `DevSession` marked
`<devProtocol>`: the kind is its selector's first keyword split before the
first capital (`processRetrySend:` is `process.retrySend`, `evaluate:receiver:`
is `evaluate`), the argument names are the method's own (parsed from its
source once per method), the description its first comment.
`protocol.describe` lists them; an argument a request does not name is an
error naming the ones it has, one it leaves out is nil. Adding a request
is compiling such a method (`DevProtocolTests>>aNewDevProtocolMethodIsANewRequest`
adds `sample.echo` through the protocol itself and calls it). A request
marked `<debuggable>` too lets an unhandled error stop its Process for
the debugger (the reply then says `stopped: ... (process N)`); every other
request answers an error with its printString.

| kind | arguments | what |
|---|---|---|
| `protocol.describe` | | every request: kind, selector, arguments, comment, debuggable |
| `class.list` | category | class names, of a category or all, sorted |
| `class.categories` | | the class categories |
| `class.definition` | className | superclass, instance, class and class-side instance variables, category, kind, comment, package |
| `class.selectors` | className, side | selectors by category (`side`: instance, the default, or class) |
| `class.tonel` | className | the session's package's file of the class: path and text |
| `method.source` | className, selector, side | source, category, package, author |
| `method.bytecodes` | className, selector, side | bytecodes, literals (printStrings), the pc-to-source map |
| `method.senders` | selector | the methods whose literals name it (special sends are not literals) |
| `method.implementors` | selector | the classes that implement it |
| `method.compile` | className, source, category, side | compile and install; the author and package are the session's; answers the selector and the files |
| `method.remove` | className, selector, side | answers the files |
| `class.define` | name, superclass, instanceVariables, classVariables, category | define, or redefine one of the same superclass and kind; the class is the session's package's |
| `class.comment` | className, comment | |
| `class.remove` | className | answers the file to remove |
| `evaluate` (debuggable) | source, receiver | a doit, self the object under a handle or nil; answers its printString, class and a handle |
| `inspect` | handle | class, printString, named slots and the first 100 indexed ones, each with a handle |
| `inspect.release` | handle | |
| `process.list` | | every live Process: id, state, priority, main, and why it is stopped |
| `process.frames` | process | a stopped Process's frames: method, pc, range, receiver, variables (names and values), source |
| `process.evaluate` | process, frame, source | a doit in a frame (below) |
| `process.proceed` | process, value | |
| `process.restart` | process, frame | |
| `process.retrySend` | process | |
| `process.step` | process, mode, frame | answers at once; `process.stopped` follows |
| `process.suspend` | process | a running or waiting Process stops for the debugger |
| `process.terminate` | process | runs its ensure blocks |
| `test.run` | filter, tag | runs TestCases, streaming 8b's events; answers failures and errors |
| `session.open`, `session.close` | | the transport's (below) |

`DevSession` keeps the session's client, package and handles. A handle is
a SmallInteger the session keeps an object under (strongly, one handle per
object) until `inspect.release` or the session's end.

### Where it runs

`DevProtocol start` (spawned by the host once the transport is open)
registers a Semaphore with the inbox (primitive 159) and forks the
**protocol Process** at the highest priority (2, background-affine). It
waits on the Semaphore, takes one request per signal (primitive 160:
`{connection. canonical JSON}`), reads it (`Json read:`), answers
`session.open` and `session.close` itself, and forks every other request
into a Process of its own at priority 1, which runs the method and replies
(primitive 161: the line to the host's event callback as it is). The
protocol Process never runs a request, so a long one (a test run, which
streams its events as it goes and replies at the end) or a stopped one
never blocks the next; requests of one connection may be answered out of
order, matched by id. Views are reached through 9a's hop primitive as
from any Process, so a request that touches a view hops to main by
itself. Every request a client may want to send again is idempotent
(`method.compile` of the same source, every read, `process.proceed` of a
Process that is no longer stopped answers an error), so a client on a
link that drops (9d) retries.

The inbox (`ShellBridge`) is the event queue's design with a mutex of its
own: a FIFO of `(connection, bytes)`, one external signal per request for
the registered Semaphore, the registration signalling once per request
already queued. Primitive 161 takes a String that is valid UTF-8, one
JSON object, no line break, and calls the host's `events` callback; the
transport routes a line starting `{"v":1,"kind":"reply","conn":N,` to
connection N and any other line to every open session. The kernel writes
its replies in exactly that form (`DevProtocol reply:result:`).

### The transport

`ProtocolServer` (`Sources/KajoDev/Server.swift`) listens on a
Unix-domain socket (mode 0600, the user's alone, before it listens; a
stale socket file is replaced, a live one or any other file refused; the
path must fit `sun_path`, 103 bytes). Each connection has a reading thread and a serial
writing queue; a client that stops reading is dropped once 64 MiB wait
for it, and a line longer than 1 MiB is a refusal. `kajo run <image>
--protocol <socket>` is a headless target (`DevTarget`: the image in a
`ShellVM` without views, its main worker turned on the calling thread,
bounded waits between turns) and prints the socket and the token; the
macOS shell takes `protocol=<socket>` in `mode=demo` and with
`debugstop=1` in `mode=scenario`, and shows the path and the token in its
status line, where it also shows every `process.stopped` so a stopped
Process cannot hide. The iOS transport is 9d.

### Who may connect

The first request of a connection must be `session.open` with the token,
the client's name (`developer` or `agent:<name>`, letters, digits, `.`,
`_`, `-`) and optionally the package its changes belong to. The token is
20 random letters and digits (`arc4random_buf`, about 100 bits), made when
the transport opens, compared in constant time, printed by `kajo run` and
shown by the Mac shell, never written to a file by the target (the
results line of the `debugstop` scenario carries the socket, not the
token). In a release image `DevTarget` refuses to start, the Mac shell
does not serve, and primitives 159 to 161 fail; `DevProtocol start`
answers false and the Debugger is never enabled.

The parser (`parseRequest`, `parseJSON`, `Sources/KajoDev/`) is the
target's trust boundary: bounded (1 MiB per line and string, depth 16,
4096 elements, integers within SmallInteger's range, finite floats, valid
UTF-8 and escapes, no NUL, no duplicate key), and the kernel is handed
only the canonical text the writer made from the value the reader
accepted. `just fuzz protocol` holds it to that (below);
`DevProtocolTests>>malformedRequestsAreRepliesAndTheTargetGoesOn` sends
300 seeded mutations of four good requests on an open session and gets
exactly one reply to each (refusals from the transport, errors or results
from the image), then a good request answered.

## 2. The debugger

### Stopping

While the protocol serves, `UnhandledError>>defaultAction` sends `Debugger
stop:` instead of reporting and terminating: the active Process becomes a
`DebugStop` (the exception, the reason, its frames from the signalling one
down, at most 256, as live Contexts) registered in `Debugger`, the reply of
the request it was running (if it was one) says `stopped: <error>
(process N)`, `process.stopped` goes to every session, a Transcript line
says so (`kajo run` prints the Transcript on stderr: the headless target's
one line), and the Process waits on the DebugStop's Semaphore. **No
timeout**: it waits until a client acts. Nothing in a release image
changes (the protocol never starts there), and without the protocol
(`kajo test`, plain `kajo run`, the shells' other modes) the error is
reported and the Process ends as before.

The stopped Process runs every command itself, on its own stack: the
request's Process queues `{selector. arguments. replyTo}` in the DebugStop
and signals it, and the stopped Process wakes, runs the command, answers
the request and waits again. That is what makes its Contexts usable: 8a
answers a Context of another Process as dead (a stack another worker may
be running is not walked), but the stopped Process's own frames are live
to it. A command that lets it go on (proceed, step) makes `serve` answer;
restart, retry and terminate unwind its stack and never come back.

### Looking

`process.frames` answers each frame's method, pc, receiver, source, and
the **source range the pc is at** from the pc-to-source map (section 6):
for the first frame of a step or suspend stop the send it is about to
make, for every other frame the send it is in. Its **variables** are
named: `Compiler frameVariablesOf:` compiles the home method's recorded
source again with the compiler in Smalltalk, keeping each scope
(`Compiler>>recordScopes`), finds the method or block being looked at by
walking the two literal trees in step, and answers each name with its
frame index and, for a captured and assigned variable, its slot in the
temp vector (arguments, copied values, the scope's own vector, the loop
bodies' vectors, the other temps; `CompilerScope>>frameVariables`). The
compiler in Smalltalk lays frames out exactly as the bootstrap compiler
(CompilerTest), so the names fit any method of the image.

### Acting

- **Evaluate in a frame** (`process.evaluate`, `Compiler evaluate:in:`):
  the statements are compiled as a method of the frame's method's class
  whose temporaries are the frame's named variables (and, for a block's
  frame, those of its home method's frame when it is on the stack below:
  the closure's home Context, else the nearest frame of the home method
  with the same receiver), read from the frames before the statements and
  written back after them (in an ensure: block), self the frame's
  receiver. An assignment reaches the frame; an operand the frame pushed
  before it stopped is not re-read.
- **Proceed**: the error's signal answers the given value (nil by
  default), whatever the error's resumability, as Pharo's proceed does; a
  step or suspend stop goes on where it stopped.
- **Restart a frame** (`process.restart`): the frame's sender runs again
  the send that made the frame, with the frame's receiver (a block frame's
  closure) and arguments, after the frames above have unwound with their
  ensure: blocks: `Context>>restartSendWith:` runs the unwind blocks
  (8b's walk, as `resume:through:` does), cuts the stack to the sender
  (`terminateTo:`), and primitive 156 drops the running frame, sets the
  sender's pc back to the start of the send instruction that ends at its
  pc (decoded from the method's start) and puts the operands where they
  were. The send looks the selector up again, so the current version of
  the method runs: **fix and continue** is `method.compile` then
  `process.restart` (`DebuggerProtocolTests>>aFixedMethodIsRestartedInItsFrame`).
  A frame entered other than by a send of its selector (a `perform:`, a
  doesNotUnderstand:) is refused with a reason (restart its sender), and
  so is the bottom frame. This answers 8b's open question 3 and 8e's
  question 3 (the running-frame rule stays; the debugger can now move a
  frame out of the way).
- **Retry a send** (`process.retrySend`, the define-and-proceed trick):
  for a Process stopped at doesNotUnderstand:, the same primitive re-runs
  the send in the doesNotUnderstand: frame's sender with the original
  receiver and the Message's arguments, after checking the send there is
  of the Message's selector. Tested with the method defined by the
  protocol on the receiver's class, on its superclass, and with a class
  defined first that the new method names
  (`DebuggerProtocolTests>>aMissingMethodIsDefinedAndTheSendRetried`).
- **Terminate**: the stopped Process runs `terminateUnwinding` (section 5).
- **Suspend** (`process.suspend`): another Process stops for the debugger
  where it stands (the interrupt of section 3), reason `suspended`.

### The UI thread

A stopped main-affine Process waits on a Semaphore like any other: the
shell's turns and every other Process go on (ADR 0004). Measured on the
macOS shell under `just mac-shell` (`scenario=idle debugstop=1`, below): a
client suspends the event loop's own Process for the whole 10 s window
and asks the target to evaluate every 50 ms meanwhile; the window kept
every frame and the target answered every request, and after `proceed`
the loop handled the events that had queued.

## 3. Stepping (ADR 0012)

**At the poll.** Primitive 158 (`Process>>primStep:frame:`, run by the
stopped Process itself) sets its record's step mode (into, over, out),
the header index of the frame stepped, and whether the frame is at a send
it is about to make (a stop at a poll) or after one (an error, a return);
its countdown is kept at 1 from then on, also when it is resumed, so
every send and backward jump of that Process takes the poll's slow path,
where `stepPoll` decides: **into** stops at the next poll after the
stopped send ran again (polls above the frame on the way back to it, the
debugger's own, are not counted); **over** at the next poll in the frame
or below it (the stopped send's own poll skipped); **out** at the next
poll below it. **Returns**: the frame is marked with a new return marker
(`FrameMarker.step`) in its context word, or in its Context's marker slot,
unless it carries 8a's discard or cascade already; a marked frame's
return takes the out-of-line return as any marked frame does, and
`stepAfterReturn` stops the Process in the caller when the record still
steps that frame (a stale marker is ignored). 8c's loader accepts the
marker in a saved frame.

**A stop is an interrupt.** The poll does not run Smalltalk: the Process
is requeued with an interrupt in its record (under the scheduler lock),
the dequeue hands it to the worker that resumes the Process, and
`runSlice` sends the Process `stopForDebugger` (the pc rewound to the
send) or `stopForDebuggerAfterSend` (after a return) from where it stands,
with the discard marker. The same interrupt, primitive 155 with kind 1,
makes another Process run `terminateUnwinding`, and with kind 2 stop for
the debugger (`process.suspend`): a ready one when dequeued, a running one
at its next poll (the attention word, as a terminate request), a waiting
one taken off its Semaphore and made ready (its stop is after the wait's
send). A Semaphore wait with an interrupt pending does not wait. After an
error, `into` is `over` (the frame goes on after the failed send).

Tested through the protocol (`DebuggerProtocolTests>>aStoppedProcessSteps`):
from a doesNotUnderstand: in `stepped:`, over stops at `self first: n`,
into in `first:` at its first send, out back in `stepped:` after
`self first: n`, over at `self second: a`; an evaluation reads and
assigns `a` there; proceed answers the method's result.

**What it costs** (Measurements): nothing on the interpreter's paths
(`interpret` 1056 instructions, one jump table; the bench A/B within
noise); a step's round trip about 1.6 ms; a stepped Process runs about
twice as slowly while it steps (every send through the poll's slow path).
The rejected alternatives, a stepping copy of the method and a second
interpreter loop, are in ADR 0012.

## 4. Sources, files and git

**Packages.** A class belongs to a package (`ClassDefinition>>package`);
a method belongs to its class's, unless it is an extension: then its own
package is recorded beside its category (`Smalltalk notePackage:of:in:`,
`packageOfSelector:in:`). The image build takes a directory's package
from its `package.st` (`Package { #name : #Sample }`), else the directory's
name capitalized (`kernel/` is Kernel), and hands every class's package
and every extension method's over (`recordDefinitions:` gained a field,
`recordSources:` the package and author lines). A session's package
(`session.open`) is the package of every class it defines and of every
method it compiles (`DevProtocol noteChangeOf:in:`, called by
`Behavior>>compile:`).

**The extension form.** `TonelWriter sourceOf: aClass package: aName`
writes the class file when the class is the package's, with the package's
methods only, else `Extension { #name : #Foo }` and the package's methods
of that class; `fileNameOf:package:` names `Foo.class.st` or
`Foo.extension.st`; `Smalltalk writePackage:into:` writes a package. 8e's
"No Extensions are written" deviation closes. The kernel's files are
unchanged byte for byte (every kernel method is the Kernel package's).

**Author marks** are method metadata: `{ #category : #accessing, #author :
#'agent:claude' }`, written only for a method a session made, read by both
Tonel readers (Swift: `TonelMethod.author`, recorded by the build;
Smalltalk: the document's fourth method field, noted by the loader), so
`git diff` and the browser show what an agent changed. A metadata key is
byte-stable where a pragma would have changed the method's bytecodes and
literals. The class definition carries no author (Deviations).

**Written on every change.** Every accepted change answers `files`: the
session's package's file of the class it touched, `{path, text}`, or
`{path, remove: true}` when the package has nothing of the class any more.
The client (`ProjectWriter`, used by the CLI with `--project`, the MCP
server with `--project`, and the tests) writes them into the project
directory, taking file names only (`Foo.class.st`, `Foo.extension.st`;
anything with a `/`, `..` or another suffix is refused). A session's
method source is kept in the form its file reads back as
(`TonelWriter canonicalSource:`: the body on lines of its own ending with
a line break), so the image and its files agree method for method.
`AgentInterfaceTests>>aSessionsProjectRebuildsTheImageItEdited` changes a
copy of the fixture project through a session (a method compiled into a
class of the package, one removed, an extension of String, a class defined
under a class of the package, a class-side method, a class comment with
quotes), builds an image from `kernel/` and the written directory, and
finds every method of the five classes the same bytecode for bytecode and
source for source, the authors and the comment the same, and the same
files written back; `theProjectWrittenOutIsTheProjectByteForByte` checks
the fixture's files are the writer's canonical form.

## 5. The agent interface

**MCP**: `kajo mcp --target <socket> [--token T] [--client agent:<name>]
[--package P] [--project dir]` (`MCPServer`) speaks JSON-RPC 2.0 on stdin
and stdout, one message per line: `initialize`, `ping`, `tools/list` (from
`protocol.describe` each time, so a new `<devProtocol>` method is a new
tool: the kind with `_` for `.`, the comment, the argument names as the
input schema's properties) and `tools/call` (one request; the result as
text, the events the target emitted meanwhile as a second text, a step's
`process.stopped` waited for, the files written into the project).
**CLI**: `kajo eval`, `kajo compile`, `kajo browse`, `kajo debug list |
frames | proceed | restart | retry | step | terminate | suspend | eval`,
`kajo test --target`, and `kajo request <kind> '<json args>'`, all over
the same client, printing JSON. The token comes from `--token` or
`KAJO_TOKEN`.

`AgentInterfaceTests>>anAgentWorksThroughMCP` drives a target through the
MCP server as an agent would: lists the tools, defines a class and its
TestCase, runs the test (it errors: the method it needs is missing; the
test events come back with the result), evaluates a doit that stops at
doesNotUnderstand: (the `process.stopped` event comes back), defines the
method, retries the send (the doit's result arrives) and runs the test
again (it passes); every change is in the project directory with
`#author : #'agent:mcp-test'`.

**What an agent may never do**, enforced in the target: nothing in a
release image (no protocol); no file outside the project directory (the
target writes nothing itself; the file primitives' one directory, 8e; the
client's writer takes file names only); no session without the token.
Otherwise an agent has the developer's rights. The rules for AGENTS.md
are the main session's to write.

## 6. Kernel items and the pc-to-source map

### `Process>>terminate` runs ensure blocks

`terminate` of the active Process runs `terminateUnwinding` at once: every
pending `ensure:` and `ifCurtailed:` block from the running frame down,
innermost first (an error in one is reported and the unwinding goes on),
then the end (primitive 24, now `primTerminate`). Another Process that has
started is interrupted (primitive 155) to run `terminateUnwinding` itself
when it is next resumed (ready: at its dequeue; running elsewhere: at its
next poll; waiting: taken off its Semaphore), and the sender waits for it
to end, at most about `Process unwindBudgetMs` (1000 ms of 1 ms Delays; the
budget 8c's save does not have, so a number of its own), then ends it
where it stands. A Process not yet started has no frame and ends at once.
The debugger's terminate and restart use the same unwinding. Tests
(`DevelopmentTest`): a waiting, a running and the active Process run their
blocks in order, and a Process whose ensure block waits forever ends
within the budget.

### Extensions of sealed classes (provisional, overturnable)

A method may be installed into a sealed class (Class, Metaclass,
CompiledMethod, MethodDictionary, Process, Context, ... and their class
sides) when it can do nothing a method of any other class could not: no
primitive, no instance-variable access (the verifier refuses it for a
sealed class anyway), and no send of `slotAt:put:`, `instVarAt:put:`,
`become:` or `becomeForward:`, a Symbol literal of them included (for
`perform:`), in the method and its blocks (`sealedExtensionProblem`).
Primitive 97 answers the refusal as a String naming the reason
(`Behavior>>addSelector:withMethod:` signals it); primitive 98 removes such
a method from a sealed class under the same rule (a kernel method of a
sealed class stays). AGENTS.md's sealing rule is the main session's to
amend. Test: `DevelopmentTest>>testSealedClassesTakeExtensionsThatOnlySend`.

### Obsolete classes freed

A removed class (8e: `AnObsolete<Name>`, cut from the hierarchy) is now
also sealed, so it makes no instance (`basicNew` refuses, as for any
sealed class). `Smalltalk garbageCollect` (a full collection, primitive
11) then runs primitive 163: in one stop, after a full collection, every
removed class with no instance, whose metaclass's only instance is the
class, is taken out of the class table and its metaclass stops naming it
(nothing else names a metaclass: classes name theirs by index); a second
full collection frees the class exactly when nothing else names it (no
literal, Binding, frame, stack word or root); its two indices become
**holes** (no class object, format 0), and a class still named goes back.
The define primitive takes the lowest pair of consecutive holes before
appending. The image loader accepts a hole past the well-known classes
and refuses any object whose class index is one; the snapshot writes
holes as they are (image version 4). Tests: a removed class freed, its
indices taken by the next class defined
(`testRemovedClassesAreFreedAndTheirIndicesTaken`); a removed class an
Array still names kept until it is let go
(`testARemovedClassStillNamedIsKept`); every image saved after such
changes passes the loader (the round trips and the snapshot seeds).

### The pc-to-source map

Both compilers record, for every send instruction of a method and of each
of its block methods, the byte range of the message in the method's
recorded source (from the receiver's start to the last argument's end;
`Node.start/end` in `Syntax.swift`, `ParseNode>>sourceStart/sourceEnd` in
the kernel's parser): a `.source` line (Swift) or `{#source. start. end}`
(Smalltalk) before the send, and the assembler writes the entries (pc
delta, start, length, unsigned LEB128) as a ByteArray, the method's last
literal, never merged with another, under method flag 16
(`MethodFlags.sourceMap`); `verifyHeapMethod` checks the flag's literal
is a ByteArray. `CompiledMethod>>sourceMapEntries`, `sourceRangeAt:`,
`sourceCode` (a block's from its home method) read it. CompilerTest
compares the maps of every method of the image between the two compilers
(they agree). Image growth: 2244 maps of 2768 methods and block methods,
12 218 entries in 44 912 bytes, the kernel image 5 020 440 bytes against
4 931 112 built without maps (**+89 328 bytes, 1.8 percent**).

## Fuzzing the trust boundary

`just fuzz protocol` (`Sources/fuzz-protocol/main.swift`, seeds in
`Tests/KajoVMTests/Fixtures/fuzz/protocol/`): each input split into lines,
each line through `parseRequest`; an accepted request's line form must
read back as the same request and its canonical form (what the kernel
gets) as the same kind and id, a refusal must make its error reply; the
whole input through `parseJSON`, an accepted value written and read back
equal; each line through the project writer's file-name rule. The four
other fuzz targets run as before; the snapshot seeds were written again
for image version 4 (`KAJO_WRITE_FUZZ_SEEDS=1`), and the three crash
fixtures of 8c and 8d are version 3 and refused at the version word now
(their rules are still checked by the loader, but these bytes no longer
reach them).

## Models

None changed, none added. Stepping is one Process's business: its step
fields are read and written only by the worker running it (the Process
sets them, its polls and returns read them), and the hand-over between
workers is the dequeue under the scheduler lock. The interrupt is the
terminate request's protocol (a record field written under the scheduler
lock, the attention word for a Process running elsewhere, the dequeue
taking it under the same lock), with two additions under that lock: a
waiting Process is unlinked and made ready as a signal does, and a
Semaphore wait with an interrupt pending requeues instead of waiting (the
case where another worker consumed the attention meant for this
Process). The protocol inbox is the event queue's design. No new wait,
flag or fence crosses threads, so the save-hold, young-collection and
relocation models are untouched.

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS 27,
swift.org Swift 6.4.2, 2026-11-04.

### The kernels against the starting commit

The starting commit's `kajo` (77766ad, from a worktree) against this
module's (d23e9b6 with the obsolete-class fix in the working tree;
`interpret` and the send and return paths are the final commit's), both
built `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
`--slice-ms 0`, 20:15 to 20:20 (load average 3.8 falling to 3.1
1-minute); median (min to max) ms. The Smalltalk kernels run from
images each binary built from its own `kernel/`. Every checksum is the
published one on both sides.

| kernel | workers | 77766ad ms | 9b ms | 9b / start | checksum |
|---|--:|--:|--:|--:|---|
| alloc | 1 | 2930.2 (2928 to 2939) | 2950.3 (2944 to 2951) | **1.007** | 41950911 |
| alloc | 8 | 472.5 (433 to 492) | 461.7 (435 to 507) | **0.977** | 42008248 |
| arith | 1 | 2539.1 (2538 to 2551) | 2548.5 (2544 to 2560) | **1.004** | 372800000 |
| arith | 8 | 344.5 (336 to 353) | 344.8 (337 to 347) | **1.001** | 372800000 |
| fib | 1 | 1697.2 (1689 to 1701) | 1717.6 (1716 to 1723) | **1.012** | 24682992 |
| fib | 8 | 216.9 (216 to 232) | 226.5 (219 to 246) | **1.044** | 24682992 |
| ivars | 1 | 1969.6 (1967 to 1973) | 1972.2 (1967 to 1974) | **1.001** | 36383626 |
| ivars | 8 | 258.0 (252 to 273) | 258.5 (252 to 284) | **1.002** | 71714128 |
| sends | 1 | 2587.1 (2581 to 2646) | 2592.8 (2585 to 2593) | **1.002** | 1066666666666668 |
| sends | 8 | 339.6 (332 to 358) | 342.6 (338 to 360) | **1.009** | 133333335000001 |
| storeheavy | 1 | 2405.6 (2399 to 2411) | 2407.2 (2397 to 2412) | **1.001** | 512000 |
| storeheavy | 8 | 320.2 (309 to 333) | 314.5 (308 to 334) | **0.982** | 512000 |
| Smalltalk closures | 1 | 3830.5 (3800 to 3855) | 3809.4 (3792 to 3825) | **0.994** | 210210000 |
| Smalltalk closures | 8 | 515.3 (498 to 518) | 498.1 (491 to 517) | **0.967** | 209214000 |
| Smalltalk ivars | 1 | 1967.9 (1966 to 1972) | 1967.7 (1964 to 1974) | **1.000** | 36383626 |
| Smalltalk ivars | 8 | 255.5 (253 to 276) | 266.0 (254 to 276) | **1.041** | 71714128 |
| Smalltalk sends | 1 | 2261.6 (2256 to 2318) | 2295.9 (2284 to 2306) | **1.015** | 1066666666666668 |
| Smalltalk sends | 8 | 307.3 (291 to 317) | 304.0 (296 to 315) | **0.989** | 133333335000001 |

- One worker: 0.994 to 1.015, every range overlapping but fib's
  (1689 to 1701 against 1716 to 1723: 1.012; five more interleaved runs
  at 20:21 gave 1697 against 1716, the same).
- Eight workers: 0.967 to 1.044, both ways, within the runs' spread.
- `interpret` is the same code in both aligned binaries: its disassembly
  (1320 lines) differs only in the page offsets of the jump table's
  `adrp` (8 lines), and `pollAndSend`, `pollAtJump`, `primitiveSend` and
  `lookupMiss` are identical instruction for instruction (calls and page
  addresses aside). `interpret` moved from 0x21a60 to 0x22c40 (both
  aligned). By AGENTS.md's rule the 1 percent on fib is the link's
  placement, not code: nothing fib executes changed but `pollSlow`'s budget
  check (once per 1024 sends: one record read) and `runSlice` (once per
  slice).

### The protocol's latencies

The release build of `just test-release`'s scratch path,
`KAJO_MEASURE=1 swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests --filter protocolLatencies`,
a target with two background workers on this machine, one client over the
Unix socket (round trip from the request's write to its reply; the step
from the request to the `process.stopped` event); three runs at 20:22
(load average 3.5 to 4.5), median of the runs' values (min to max):

| | p50 | p99 | requests per run |
|---|--:|--:|--:|
| `protocol.describe` | 2.37 ms (2.33 to 2.39) | 2.61 ms (2.56 to 2.99) | 200 |
| `method.compile` (a one-line method) | 0.85 ms (0.85 to 0.89) | 1.02 ms (0.99 to 1.03) | 100 |
| `evaluate` (`3 + 4`) | 0.21 ms (0.21 to 0.22) | 0.26 ms (0.25 to 0.40) | 200 |
| `process.step` into, to its `process.stopped` | 1.59 ms (1.59 to 1.62) | 1.83 ms (1.82 to 1.85) | 40 |
| stepping over `spin: 200000` (400 000 sends) against running it | 9.48 ms (9.41 to 9.75) | 4.95 ms unstepped (4.92 to 5.05) | 3 |

`protocol.describe` makes the request table again from the pragma index
and writes 28 entries; the first version parsed every request's source
for its argument names each time (6.7 ms), now kept per method. A compile
is the compiler in Smalltalk, the make, the install stop and the Tonel
text of the class for the reply.

### Stepping's cost

On the interpreter: none. `interpret` is 1056 instructions with one jump
table (`just arc-check`, as at the start), the send and return fast paths
unchanged; `pollSlow` gained one read of the running Process's record at
its budget check and `runSlice` one when it resumes a Process; the bench
A/B above is within noise. On the stepped Process: stepping over a send
of 400 000 sends (`SampleDebug>>spin:`) takes about twice as long as
running it unstepped (9.5 against 4.9 ms, above), every send of the stepped Process going
through the poll's slow path to be compared with the frame stepped.

### The macOS shell: a stopped event loop

`just mac-shell run <out> mode=scenario scenario=idle debugstop=1 seconds=10
warmup=1 workers=5`, the Mac mini's 120 Hz display, three runs (thermal
nominal): the event loop's Process (main-affine) suspended for the
debugger for the whole window, a client evaluating `3 + 4` every 50 ms.

| | run 1 | run 2 | run 3 |
|---|--:|--:|--:|
| frames (of 1200), missed | 1200, 0 | 1200, 0 | 1200, 0 |
| max gap | 8.4 ms | 8.4 ms | 8.4 ms |
| stopped for | 9.95 s | 9.95 s | 9.98 s |
| protocol replies, errors | 182, 0 | 182, 0 | 182, 0 |
| round trip p50, p99, max | 1.41, 2.51, 5.68 ms | 1.37, 2.15, 2.63 ms | 1.38, 1.96, 2.04 ms |
| events handled while stopped, in 0.5 s after proceed | 0, 98 | 0, 77 | 0, 53 |

The main thread kept every frame and the target answered every request
while the main-affine event loop was stopped; nothing ran in it until it
was let go, then it handled the frame events that had queued.

### The image and the tests

The kernel image is 5.02 MB with 1932 methods and 159 classes (8e: 4.27
MB, 1737 and 152): the protocol, the debugger and JSON (seven classes),
the source maps (89 KB), the tests. `kajo test` runs 192 kernel tests
(179 at the start; `DevelopmentTest` 13).

## Changes to earlier modules

- **Module 1**: class-table holes (`isClassHole`, `makeClassHole`,
  `freedClassPair`).
- **Module 3**: the Process record's interrupt and step fields; the
  dequeue hands the interrupt to the worker; `runSlice` runs it and keeps
  a stepped Process's countdown at 1; `pollSlow` requeues a Process with
  an interrupt pending and calls `stepPoll`; `waitSemaphore` does not wait
  with an interrupt pending; `unlinkLocked` is internal. Counters
  `interruptsAsked`, `interrupts`, `stepStops`, `resends`,
  `protocolRequests`, `protocolReplies`.
- **8a**: method flag 16 and the source map literal (`verifyHeapMethod`
  checks it); `FrameMarker.step` and `returnSlow`'s call of
  `stepAfterReturn`; primitives 155 to 158, 162, 163; three VM selectors
  (`terminateUnwinding`, `stopForDebugger`, `stopForDebuggerAfterSend`);
  image version 4 (holes allowed, no object of a hole); the install
  primitive's sealed-extension rule and String refusal; a removed class's
  format sealed.
- **8b**: both compilers' source ranges and maps; `Process>>terminate`
  unwinds; `UnhandledError>>defaultAction` stops while the protocol
  serves; `Pragma consumesPragmas` declares `debuggable` and `devProtocol`
  is read; `recordSources:` and `recordDefinitions:` carry packages and
  authors; `Smalltalk evaluate:` and `evaluateStrings:` for hosts; the
  Compiler keeps scopes on request and evaluates in a Context.
- **8c**: the saved-frame rules accept `FrameMarker.step`.
- **8d**: `Behavior>>compile:` notes the session's author and package;
  `addSelector:withMethod:` and `removeSelector:` signal the VM's reason.
- **8e**: the Tonel writer's package and extension forms and author
  metadata; the readers read `#author`; `ClassDefinition>>package`;
  `Smalltalk garbageCollect` frees obsolete classes; `writePackage:into:`.
- **9a**: `ShellVM.openProtocol`, `postRequest`, `queuedRequests`; the
  snapshot test waits for the resumed image's hook (`Smalltalk
  resumeCount`: the hook detaches every wrapper it finds, and a counter
  built before it ran was detached once under load); the
  bridge's inbox; `ShellRuntime.serveProtocol(socket:)`, `stopProtocol`;
  the demo's and the scenario's `protocol=`; `debugstop=1`.
- The CLI: `kajo run --protocol`, `eval`, `compile`, `browse`, `debug`,
  `test --target`, `request`, `mcp`. `KajoShellCore` depends on `KajoDev`.

## Deviations from the brief

- **One Process per request** besides the one protocol Process (the brief
  allowed a second protocol Process): the protocol Process only reads and
  dispatches, so no request, however long or stopped, blocks another.
- **Requests are methods of `DevSession`**, not of any class: the
  dispatcher reads the `<devProtocol>` methods of that class (an extension
  from another package adds one). Arguments a request leaves out are nil.
- **Stopping is enabled by the protocol**, not by the image being a
  development image: without a serving protocol (`kajo test`, plain `kajo
  run`, the shells' other modes) an unhandled error still reports and
  ends the Process, because nothing could ever act on a stopped one there
  and the kernel's tests rely on errors ending Processes.
- **Handles are strong** until released or the session ends; the brief's
  "Ephemeron rule 9a uses for views" is not needed for an object the client
  holds by intent.
- **Proceed answers nil (or the given value) from the error's signal**
  whether or not the error is resumable, as Pharo's debugger does.
- **Restart re-executes the send in the sender** (the current version of
  the method is looked up again) rather than rewinding the frame's own pc;
  a frame entered by `perform:` or doesNotUnderstand: is refused (restart
  its sender).
- **Stepping stops at sends and backward jumps**, not at every bytecode;
  special sends whose fast path applies (`+`, `at:` on an Array) do not
  stop, and after an error `into` is `over`.
- **Evaluate in a block's frame** sees the block's variables and its home
  method's frame's when that frame is on the stack; variables of
  intermediate blocks are not reached.
- **The class definition carries no author**: authorship is per method
  (the class file's methods carry it).
- **The terminate budget** is 1000 ms of 1 ms Delays of the terminating
  Process's waiting (8c's save has no such budget to reuse).
- **Obsolete classes are freed by `Smalltalk garbageCollect`**, a full
  collection the kernel asks for, not by every collection the VM runs.
- **The fuzz crash fixtures of earlier modules** are version 3 images and
  now refused at the version word.
- **The socket path** must fit `sun_path` (103 bytes): the scratchpad and
  long project paths do not, so targets put the socket in the temporary
  directory.

## Tests

Swift: 312 `KajoVMTests` (as at the start) and 70 `KajoCompilerTests`
(Swift Testing's count; 56 at the start): `DevProtocolTests` (6: the
request parser, the token, a release image, 300 malformed requests, changes
installed, marked and written, a new request by a new method),
`DebuggerProtocolTests` (4: define-and-proceed three ways and a refused
retry, fix and restart with a frame's variables and an evaluation, steps
into, over and out with an assignment, terminate with an ensure block and
suspend), `AgentInterfaceTests` (3: the fixture written out byte for byte,
a session's project rebuilding the image, an agent through MCP),
`ProtocolMeasureTests` (1, `KAJO_MEASURE=1` only); `ClassVariableTests`'s
literal check takes the map. Smalltalk: 192 kernel tests (179 at the
start): `DevelopmentTest` (13: a send run again from a Context, evaluate in
a Context and in a block's, extension files and author marks, Json, freed
classes and their indices taken, a removed class still named kept, the
request kinds, sealed extensions, the source map and `sendBeforePc`,
terminate of a waiting, a running and the active Process and of one whose
ensure block hangs); `CompilerTest` and `ClassVariableTest` take the map.

## Broken variants run by hand

Each run on the final code with one rule broken, then put back; the
outputs are kept with the gates' (`m9b/broken/`).

| rule | broken variant | test | result |
|---|---|---|---|
| no session without the token | the transport accepts any token | `DevProtocolTests>>noSessionWithoutTheToken` | fails: "an error was expected but none was thrown": the session opened with `not-the-token` |
| a removed class still named is kept | primitive 163 makes holes of every candidate without looking at the second collection | `DevelopmentTest>>testARemovedClassStillNamedIsKept` | fails: "Assertion failed": the class an Array holds is gone from the table (a later use of it would name a hole) |
| into skips the debugger's own polls and the stopped send | `stepPoll` stops at the first poll in into | `DebuggerProtocolTests>>aStoppedProcessSteps` | fails: into stops in `BlockClosure>>on:do:` (the debugger's own frames on the way back), out then in `DebugStop>>serve` |
| a frame restart runs the ensure blocks above | `restartSendWith:` cuts the stack without the unwind walk | `DevelopmentTest>>testAContextRunsItsSendAgain` | fails: "Assertion failed": the log is `(1 2)`, no `#ensure` |
| a sealed class takes only message-sending methods | the install primitive skips `sealedExtensionProblem` | `DevelopmentTest>>testSealedClassesTakeExtensionsThatOnlySend` | fails: `developmentExtensionSample ^ self slotAt: 1 put: 2` is installed |
| a running Process leaves at its next poll to run its interrupt | `pollSlow` does not requeue it | `DevelopmentTest>>testTerminateRunsTheUnwindBlocksOfARunningProcess` | **passes**: the running Process is preempted at its slice's end (5 ms), requeued, and runs the interrupt when resumed; the poll's check makes it run at the next budget check instead, and is the only way with time slices off (`--slice-ms 0`); kept as a latency rule, not tested |

## Unsafe surface

`Sources/KajoVM` lines with `unsafe` (comments excluded): 4753,
against 4608 at the start (77766ad): `Processes/Debugging.swift` 97 (the
records and the scheduler lock, the stack of the running Process for the
resend and the step marker, the countdown, the interrupt's push),
`Shell/ShellBridge.swift` 16 (the inbox's mutex), `Shell/ShellPrimitives.swift`
6, `Shell/Shell.swift` 1, `Workers/Poll.swift` 6 and `Run.swift` 6 (the
interrupt and the step at the poll and the resume), `Processes/Scheduling.swift`
7 (the dequeue's hand-over, the wait's check), `ObjectMemory/Roots.swift`
3 (holes), `ObjectModel/LiveClasses.swift` 1, `ObjectModelPrimitives.swift`
1, `Frames.swift` 1. `KajoDev` (strict memory safety on) has 16: the
socket calls in `Server.swift` (12) and `Client.swift` (4);
`fuzz-protocol` 1 (libFuzzer's buffer). Counted on the final commit's
clean build (0 warnings).

## Hot-path check

`just arc-check` on the final code: 135 functions, zero `swift_retain`/`swift_release`; `interpret` 1056 instructions (as at the start), one jump table. Nothing of this module is on
the checked dispatch, send, return or allocation paths: the new primitives
are reached through `primitive`'s switch (one out-of-line call each
range); the step is in `pollSlow` (out of line, after its early return)
and `returnSlow` (already out of line for any marked frame); the interrupt
in `runSlice` and `dequeueLocked`, which run once per slice.

## Not done

- The developer UI (9c) and the phone transport (9d).
- Stepping per bytecode, and stops at special sends whose fast path
  applies.
- Restarting a frame entered by `perform:` or doesNotUnderstand:.
- Evaluating in a block's frame with the variables of intermediate blocks.
- Sending a stopped request's eventual result (its reply said it stopped).
- An author on class definitions; a package's `package.st` written by the
  image.
- Freeing obsolete classes at collections the VM runs by itself.
- Redefining a class with another superclass (8e's, the owner: later).
- Compile warnings as events (8b, agreed, not built).

## Open questions for the owner

1. **Stopping without a client.** Unhandled errors stop only while the
   protocol serves; in a development image run without it they still end
   the Process with a report. Should a development image always stop (and
   the shells always serve), so a later client finds the stopped Process?
   Provisional: only while serving.
2. **The author mark's place.** Method metadata (`#author`), byte-stable,
   read by both readers, invisible to Pharo's Tonel tools that ignore
   unknown keys. Keep it there, or as a pragma (which changes the
   method's bytecodes and literals and would be compiled)?
3. **Sealed extensions** (provisional, the brief's answer): a method that
   only sends may join a sealed class. Keep, or refuse again?
4. **The terminate budget**: 1 s, then the Process ends where it stands.
   Right for an ensure block that waits forever?
5. **What an agent may do.** The same rights as the developer, in the
   session's package; should an agent's session be refused some requests
   (`process.terminate` of Processes it did not start, `class.remove`),
   or confined to its package's classes?

### The owner's answers (2026-11-06)

1. **Yes**: a development image stops an unhandled error's Process
   whether or not a client is connected, so a later client finds it. To
   be built in a follow-up (as built here it stops only while serving).
2. **A pragma.** The author mark moves from method metadata to a pragma;
   to be built in the same follow-up, with the canonical Tonel form and
   both readers.
3. **Keep it**: a method that only sends may join a sealed class.
4. **Whatever makes sense for an app runtime.** The main session's
   reading: an app cannot have a Process that cannot be ended, so the
   bound stays (1 s); what a runtime needs beside it is that a cut-off
   unwinding is never silent, so `terminate` answers whether the blocks
   ran to their end and a cut-off is counted and reported. The follow-up
   checks what is built against that.
5. **The same rights for now.**

## What 9c needs

From the protocol, every request above; the browser `class.list`,
`class.categories`, `class.definition`, `class.selectors`,
`method.source`, `method.senders`, `method.implementors`, `class.tonel`;
the editor `method.compile`, `method.remove`, `class.define`,
`class.comment`, `class.remove` and the `files` of their replies (the UI
writes them as the CLI does); the workspace `evaluate`, `inspect`,
`inspect.release`; the debugger `process.list`, `process.frames` (frames
with ranges and variables), `process.evaluate`, `process.proceed`,
`process.restart`, `process.retrySend`, `process.step`,
`process.suspend`, `process.terminate`, and the `process.stopped` and
`process.resumed` events; the test runner `test.run` and 8b's `test.*`
and `run.*` events; the transcript the `transcript` events; the target
picker the socket and token of each target. In the UI's own image the
same requests can be sent to itself, or the classes behind them
(`DevSession`, `Debugger`, `DebugStop`) used directly. Two requests 9c
will likely add as methods: a class hierarchy (`class.hierarchy`) and a
method's versions. View wrappers it needs beyond 9a's: a multi-line text
view with selection, styling (the source range highlighted) and key
events; an outline (tree) view; a table or list view with selection; a
split view; menus and keyboard shortcuts; a scroll view; buttons with
images; a window with a toolbar.

**As 9c used it** (`docs/modules/developer-ui.md`): every request above
is a message of the Smalltalk client (`DevClient`, compared with
`protocol.describe` by `DevClientTest`); the tools send all of them but
`class.list`, `class.categories`, `class.tonel`, `method.bytecodes`,
`process.list` and `process.suspend` (left to scripts and agents). Three
requests were added as `<devProtocol>` methods: **`class.hierarchy`**
(every class with its superclass, category and package: the browser's
class tree in one request), **`package.list`** and
**`package.selectors`** (every method of a package, the measurement's
20 000 selectors). Two things 9b did not need and 9c changed: a reply or
event longer than one heap object (32 KiB) could not be written at all,
so the kernel writes replies and events in pieces (`Json writePieces:`,
primitive 161 taking an Array of Strings and ByteArrays it joins), and
the client's transport hands a long line to the image in pieces as well;
and the session token never enters the client image (the host's
`ClientHost` opens the session). The `files` of every reply are written
by the client's transport into the project directory given at connect, as
the CLI does. Still not done: a request whose canonical text exceeds one
heap object (a method source over 32 KiB) cannot reach the image
(primitive 160 cannot make the String) and gets no reply; buttons with
images; method versions.

## Gates

The code and this doc but for this table, the unsafe count and the
hot-path paragraph are e40c1f5's; every gate ran on e40c1f5, Mac mini (M2
Pro), swift.org 6.4.2, 2026-11-04 22:35 to 2026-11-05 00:27, every output
in a file, each step logged with the commit it ran on (`gates.log`, 0
files changed). Three earlier attempts found three things, fixed before
this run: 8d's `LiveCompileTest>>testSealedClassesStayClosed` written for
the old sealing rule, a race in 9a's snapshot test (the resumed image's
hook detached a counter built before it ran; the test now waits for
`Smalltalk resumeCount`), and the image loader's bad-version case naming 4
(now current); then `just test-release` found an interrupt refused for a
Process on its first slice (fixed: e40c1f5).

| gate | result |
|---|---|
| `swift test` | 312 + 70 passed, 229 + 70 s |
| under load (12 busy loops) | 312 + 70 passed, 273 + 85 s |
| ThreadSanitizer | 312 + 70 passed, 0 reports, 500 + 1758 s |
| ThreadSanitizer under load | 312 + 70 passed, 0 reports, 632 + 2170 s (the busy loops kept at twelve throughout) |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release in 135 functions, `interpret` 1056 instructions, one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 312 + 70 passed |
| `just model-check` | 28 + 5 + 15 passed |
| `just soak` | passed: 1000 seeds under every configuration, no failing seed; the snapshot modes saving 762 to 981 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.30 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 3.36 million runs (the version 4 seeds), no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 0.96 million runs, no crash |
| `just fuzz protocol 600` | libFuzzer build ok, 3.64 million runs, no crash |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| clean build | exit 0, 0 errors, 0 warnings |

(312 is `KajoVMTests`, 70 `KajoCompilerTests`, whose kernel-image suite
runs the kernel's 192 SUnit tests.) The four fuzzers ran at the same time,
one core each. The clean build took 10 s from an empty scratch path (the
toolchain's compilation cache); `just ios-check` typechecks every KajoVM
file with strict memory safety from nothing and reports no warning either.

## Commands

```zsh
kajo run kernel.img --protocol $TMPDIR/k.sock      # serve; prints the socket and the token
export KAJO_TOKEN=<token>
kajo eval --target $TMPDIR/k.sock '3 + 4'
kajo compile --target $TMPDIR/k.sock Foo --source 'bar ^ 1' --package P --project dir
kajo debug --target $TMPDIR/k.sock list | frames 12 | step 12 over 1 | retry 12 | proceed 12
kajo request --target $TMPDIR/k.sock protocol.describe
kajo mcp --target $TMPDIR/k.sock --client agent:claude --package P --project dir
just fuzz protocol 600
just mac-shell run out.txt mode=scenario scenario=idle debugstop=1 seconds=10
KAJO_MEASURE=1 swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests --filter protocolLatencies
```

## The owner's answers to the draft's questions (2026-11-04)

1. Developer UI language: **Smalltalk** ("I do want the development tools
   to be Smalltalk too. Swift is for the compiler and bindings"). The UI
   is module 9c.
2. Phone transport: **agreed**, TCP with Bonjour and a pairing token,
   development images only. Module 9d.
3. Agent interface: **both MCP and CLI, changes marked**; "we will need to
   iterate on this later".
4. Debugger scope: **stepping as soon as possible, and the "call an
   undefined method, stop, define the method, proceed" trick**.
5. Stopped Processes: **agreed**, no timeout in development, a release
   image never stops.
6. Sources: **on every compile**; "will need to iterate on this".
