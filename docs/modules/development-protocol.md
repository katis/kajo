# Module 9b: the development protocol, the debugger and the agent interface

Status: brief, 2026-11-04, from the owner's answers of the same day to the
draft's six questions (recorded at the end). Builds on 8b's event stream,
8d's live methods, 8e's live classes, 9a's shells and host surface, and
ADR 0004's debugger remarks. AGENTS.md's first use case is this module and
the two after it: "Develop iOS app remotely and live from Macbook, with a
Smalltalk developer UI in the Macbook with AI agent integration". The
owner's rule for the split: **Swift is for the compiler and the bindings
to AppKit and UIKit; everything a developer uses is Smalltalk.** Module 9
is therefore three builds:

- **9b (this brief)**: the protocol, its headless transport and clients,
  the debugger's target side with stepping, sources to the project
  directory, the agent interface (MCP and CLI), and the kernel items the
  owner decided alongside (obsolete classes freed, extensions on sealed
  classes, `terminate` running ensure blocks). Everything here is
  testable headless.
- **9c (next brief)**: the developer UI in Smalltalk in the macOS shell:
  browser, inspector, debugger, test runner, transcript, workspace, target
  picker, over a second round of view wrappers (text view, outline view,
  table, split view, menus, keyboard).
- **9d (after)**: the transport to the phone (TCP, Bonjour, pairing
  token) and the first remote session measured.

## What it hides

- How a developer, or an agent, reaches a running image: the one
  protocol every tool speaks, its transport to a local image, and who may
  connect.
- What the debugger is made of: how an error in the target becomes a
  stopped Process the developer can look at, step and restart, without
  the target's UI freezing.
- Where sources live and how an edit in a running image reaches a file
  and a commit.
- What an agent sees and may do, and what it may never do.

## 1. The protocol

One protocol, spoken by the developer UI (9c), by the `kajo` CLI and by
the agent interface, to one **target image** (the app under development:
the iOS shell on the phone, the macOS shell, or a headless `kajo run`).

- **Form.** Messages are JSON objects, one per line, both directions, with
  `"v"`, an `id` for request and reply, and a `kind`. The target's side is
  8b's NDJSON event stream grown up: every event the stream has today
  (`transcript`, `test.*`, `gc`, `run.*`) is a protocol event unchanged,
  and the protocol adds requests and replies. Errors are replies, never
  dropped connections.
- **Vocabulary**, by what 8b to 8e provide in the image: browse (classes,
  categories, selectors, a method's source and bytecodes, senders and
  implementors, class comments, the class definition), compile and install
  (`Behavior>>compile:`), define, redefine and remove classes (8e),
  evaluate (a doit with a receiver), inspect (an object's class, slots,
  printString; a handle the client keeps across requests, released when
  the client lets go, with the Ephemeron rule 9a uses for views),
  Processes (list, state, stack as Contexts, suspend, resume, terminate),
  run tests (8b's harness with its events streamed), write sources (3),
  and the debugger (2). **Every request is a Smalltalk method in the image
  tagged `<devProtocol>`** (the pragma 8b declared and nothing reads yet):
  the protocol's surface is the set of such methods, discoverable through
  the protocol (`protocol.describe` lists them with their argument names
  and comments). Adding a request is adding a method.
- **Where it runs.** A protocol Process in the target image at a high
  priority, main-affine only for requests that touch views (9a's hop
  rule), reading requests from a transport primitive and answering through
  the event callback 9a's host surface has (`ShellCallbacks.events`), so
  the shell owns the socket and the image owns the meaning. A request that
  takes long (a test run) streams events and replies at the end; the
  Process serves other requests meanwhile only if they cannot block it
  (design this; a second protocol Process is acceptable).
- **Transport in this module.** A Unix-domain socket the host opens for
  `kajo run --protocol <path>` and the macOS shell (the shell shows the
  path). The iOS transport is 9d; the protocol must not assume a reliable
  low-latency link (requests carry everything they need, replies are
  idempotent to retry where that is cheap).
- **Who may connect.** The protocol opens only in a development image: in
  a release image (8d's flag) there is no protocol Process and the
  transport primitive fails. A pairing token (a short random string the
  target shows once: printed by `kajo run`, shown in the Mac shell's
  window) that the client presents in its first message; no token, no
  session. The owner accepted this for the phone too (9d).

## 2. The debugger

ADR 0004: a stuck report "in the real system opens the debugger"; the frame
reserves a slot for its Context, and a Context is a first-class copy of a
frame a debugger can hold (ADR 0009 section 3). Build on that.

- **An unhandled error stops the Process**, it does not terminate it: the
  kernel's default `Error>>defaultAction` (today: terminate with the
  report) suspends the Process with its stack intact and emits
  `process.stopped` with the error, the Process and its Contexts. A
  client resumes, terminates or debugs it. **Owner: no timeout in a
  development image** (a stopped Process waits until a client acts; the
  Mac shell shows a stopped Process in its window so it cannot hide; the
  headless `kajo run` prints one line and keeps running); **a release
  image never stops**: it terminates the Process and logs the error as
  today.
- **Looking**: the Contexts of a stopped Process, each with its method,
  pc, receiver, arguments, temporaries, and the source range the pc maps
  to: both compilers record a pc-to-source map in the method (a literal,
  read-only like the rest; measure the image growth), and the Context
  answers it.
- **Acting**: evaluate in a Context (a doit compiled against the Context's
  method's class with the Context's temporaries as its variables, reading
  and writing them), **restart** a frame (8b's open question 3: the frame
  is unwound to its start and re-enters its method, the current version
  of it; ensure blocks of the unwound frames run), **proceed** (resume
  where it stopped: for an error, as if `Error>>retry`/`resume` by the
  error's rule), **terminate** (running ensure blocks; see 5), and
  **stepping**: into, over and out, **in this version by the owner's
  wish**. Stepping is a per-Process single-step mode the interpreter
  honours at its existing poll points plus at every send and return of
  the stepped Process only: the flag lives in the Process, the hot path
  checks nothing new (`just arc-check` and the bench A/B decide; one
  acceptable design is a stepping copy of the method, or running the
  stepped Process on a slow interpreter loop entered from the poll, so
  the fast loop is untouched). Design it, measure it, document the
  alternative you rejected.
- **The define-and-proceed trick, by the owner's wish**: calling a method
  that does not exist stops the Process at the `doesNotUnderstand:`; the
  developer defines the method (compile into the receiver's class, or
  define a class first) and proceeds, and the original send is retried
  against the new method with the same receiver and arguments, as Pharo's
  "create method" then proceed does. Build it as: the stopped Process's
  Contexts include the sender's at the send; `process.retrySend` unwinds
  to the sender and re-executes the send (pc back to the send
  instruction, operands restored from the Context). Test it with the
  method defined by the protocol while stopped, with a class defined
  first, and with the method defined on a superclass.
- **Fix and continue**: compile the method of a stopped frame (8d),
  restart that frame on the new method.
- **The UI thread**: a stopped main-affine Process must not freeze the
  app. The stopped Process just sits; the shell's event loop and other
  Processes continue (ADR 0004's budgeted preemption). Test on the macOS
  shell under `just mac-shell`: a scenario that stops the event-handling
  Process and shows the window still redraws and another Process still
  answers the protocol.

## 3. Sources, files and git

8e makes the image the editor's model and writes Tonel. The project the
developer edits is a directory of Tonel files on the Mac (like `kernel/`
and `apps/Shared/smalltalk`), under git, with the image built from it by
`kajo build-image`.

- The target image is the truth while it runs; **sources are written to
  the project directory after every successful compile, define, redefine
  or remove** (owner: "fine, iterate later"), by the client side (the
  developer's Mac), so a `git diff` shows what the session changed and the
  developer or the agent commits. The write is the changed class's file
  only.
- **Extension files.** A method a project adds to a class another file
  owns (a kernel class, say) is written to the project's
  `<Class>.extension.st`, Tonel's extension form, not into `kernel/`. The
  image therefore records each method's **package** (the project it came
  from; the kernel is one package) beside its category; 8e's writer gains
  the extension form and 8e's "No Extensions are written" deviation
  closes. The round-trip test covers a project directory with extensions.
- A rebuilt image from the files equals the edited image method for
  method (8e's round-trip test extended to a project directory).

## 4. The agent interface

- The agent speaks the same protocol through an **MCP server** the `kajo`
  CLI hosts (`kajo mcp --target <socket>`): tools for every protocol
  request (discovered from `protocol.describe`, so a new `<devProtocol>`
  method is a new tool without a code change), with the target's events
  streamed as the tool results' context; and a plain **CLI** over the
  same client code (`kajo eval`, `kajo compile`, `kajo test`,
  `kajo browse`, `kajo debug`) for scripts and for an agent in a
  terminal. **Owner: both, iterate later.**
- **Agent changes are marked** (owner: yes): a client identifies itself
  (`developer`, `agent:<name>`) in its first message, and every method or
  class change the protocol installs records the author in the method's
  recorded source metadata (written to Tonel as a method pragma or a
  metadata line, decide which and keep it byte-stable), so the browser
  (9c) and `git diff` show what the agent changed.
- **What an agent may never do** is enforced in the target, not in the
  client: nothing in a release image; no file write outside the project
  directory (8e's rule); no session without the token. The same rights as
  the developer otherwise.

## 5. Kernel items decided alongside (the owner's answers of 2026-11-04)

- **Obsolete classes are freed** (8e's question 4, owner: "they should be
  cleaned"): a removed class keeps its class object until a full
  collection finds no object naming it (no instance, no literal, no
  Binding, no frame), then its class-table indices are freed and reused;
  the image loader accepts a hole in the class table (an index that names
  nothing) and the saved image records holes. Rule and test for: a save
  with a hole, an instance made after a removal (refused, the class is
  obsolete), a new class taking a freed index.
- **Extensions on sealed classes** (8d's question 2, owner asked "what
  about extensions?"; provisional answer, overturnable): a method may be
  installed into a sealed class (Class, CompiledMethod, MethodDictionary
  and their class sides) **only if the verifier finds no instance-variable
  access, no `slotAt:put:`, no primitive and no `become`** in it: such a
  method can only send messages, which any other class could do already.
  The install primitive refuses otherwise with the reason. AGENTS.md's
  sealing rule is amended by the main session.
- **`Process>>terminate` runs ensure blocks** (8b's Not done, 8d's
  question 3, owner: 9b): terminating a Process unwinds its frames
  running every `ensure:` and `ifCurtailed:` block on the way, in the
  terminated Process, bounded (a block that does not return terminates
  the Process anyway after the budget 8c's save uses). The debugger's
  terminate and restart use the same unwind.

## Order (the build's, provisional)

1. The kernel items (5): obsolete classes, sealed-class extensions,
   `terminate` unwinding; the pc-to-source map in both compilers; the
   package per method and the extension form in the writer and reader.
2. The protocol Process, `<devProtocol>` discovery, the vocabulary over
   8b to 8e, the Unix-socket transport in `kajo run` and the macOS shell,
   the token, the `kajo` CLI client; tests against a headless target.
3. The debugger's target side: stop on error, Contexts, evaluate in a
   Context, restart, proceed, terminate, retry-send; tests headless.
4. Stepping: design, measurement, tests; `just arc-check` and the bench
   A/B unchanged.
5. Sources to the project directory on every change, with extensions and
   author marks; the round trip on a project directory.
6. The MCP server and the CLI for agents; a test that drives a session
   through MCP (define a class, compile a method, run its test, stop on an
   error, fix and proceed) against `kajo run`.
7. The macOS-shell scenario with a stopped Process and a live window.

## Rules

Those of AGENTS.md. The interpreter's hot path stays as it is: stepping,
the stop-on-error rule and the protocol Process add nothing to it (`just
arc-check`, bench A/B within noise). The protocol Process is one Process;
its latency is measured (round trip of `protocol.describe`, of a compile,
of a step) and tabled. The token is never written to a file by the target.

## Deliverables

The code and tests; this file as built; an ADR for the protocol (form,
`<devProtocol>` discovery, the stop-on-error rule, the token, the author
mark) and one for stepping's mechanism; ADR 0004 amended where the
debugger lands; ADR 0009 Built (9b) notes for the pc-to-source map, the
package slot and the class-table hole; CONTEXT.md terms; the rules the
agent interface enforces written in AGENTS.md by the main session; the 9c
brief's needs listed (which protocol requests the UI will call, which
wrappers it needs).

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
