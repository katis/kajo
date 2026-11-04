# Module 9b: the development protocol and the developer UI (draft for the owner)

Status: draft brief, written 2026-11-04. Not started. The decisions marked
**owner** below are the ones the main session will not take alone; the
rest have provisional answers the build would follow. Builds on 8b's event
stream, 8d's live methods, 8e's live classes (building), 9a's shells and
host surface, and ADR 0004's debugger remarks. AGENTS.md's first use case
is this module: "Develop iOS app remotely and live from Macbook, with a
Smalltalk developer UI in the Macbook with AI agent integration".

## What it hides

- How a developer, or an agent, reaches a running image: the one
  protocol every tool speaks, its transport to a local image and to the
  phone, and who may connect.
- What the debugger is made of: how an error in the target becomes a
  stopped Process the developer can look at, step and restart, without
  the target's UI freezing.
- Where sources live and how an edit in a running image reaches a file
  and a commit.
- What an agent sees and may do, and what it may never do.

## 1. The protocol

One protocol, spoken by the developer UI, by the `kajo` CLI and by the
agent interface, to one **target image** (the app under development: the
iOS shell on the phone, the macOS shell, or a headless `kajo run`).

- **Form.** Messages are JSON objects, one per line, both directions, with
  `"v"`, an `id` for request and reply, and a `kind`. The target's side of
  it is 8b's NDJSON event stream grown up: every event the stream has
  today (`transcript`, `test.*`, `gc`, `run.*`) is a protocol event
  unchanged, and the protocol adds requests. Provisional, not **owner**:
  it is what 8b decided ("the core event protocol the shells and the
  remote development UI consume later").
- **Vocabulary**, by what 8b to 8e already provide in the image:
  browse (classes, categories, selectors, a method's source and its
  bytecodes, senders and implementors, class comments), compile and
  install (`Behavior>>compile:` through 8d), define and reshape classes
  (8e), evaluate (a doit with a receiver, 8d), inspect (an object's class,
  slots, printString, a handle the UI keeps across requests with the
  Ephemeron rule 9a uses for views), Processes (list, state, stack as
  Contexts, suspend, resume, terminate), run tests (8b's harness with
  the events streamed), write sources (8e's Tonel writer, to the
  developer's project directory, see 3), and the debugger (2). Every
  request is a Smalltalk method in the image tagged `<devProtocol>` (the
  pragma 8b declared and nothing reads yet): the protocol's surface is
  the set of such methods, discoverable by the protocol itself.
- **Where it runs.** A Process in the target image at a high priority,
  main-affine only for requests that touch views (the hop rule), reading
  requests from a transport primitive and answering through the event
  callback 9a's host surface already has (`ShellCallbacks.events`), so
  the shell owns the socket and the image owns the meaning.
- **Who may connect.** The protocol opens only in a development image
  (8d's release flag: a release image has no protocol Process and the
  transport primitive fails). Provisional: a pairing token the target
  shows once (on the phone's screen, in the Mac shell's window) and the
  client presents; no token, no connection. **owner**: is a token enough
  for a phone on the home network, or do you want the transport bound to
  USB only (below)?

## 2. The debugger

ADR 0004: a stuck report "in the real system opens the debugger"; the
frame reserves a slot for its Context, and a Context is a first-class
copy of a frame a debugger can hold (ADR 0009 section 3). Build on that:

- **An unhandled error stops the Process**, does not terminate it: the
  kernel's default `Error>>defaultAction` (today: terminate with the
  report) suspends the Process with its stack intact and emits a
  `process.stopped` event with the error, the Process and its Contexts.
  A client resumes, terminates, or debugs it. Without a client connected
  the target behaves as today after a timeout (**owner**: how long, and
  should a release image ever stop a Process this way? provisional: 0 s
  and no).
- **Looking**: the Contexts of a stopped Process, each with its method,
  pc, receiver, arguments, temporaries, the source line the pc maps to
  (the compilers record a pc-to-source map, 8b has the sources; add the
  map if missing).
- **Acting**: evaluate in a Context (a doit compiled against the
  Context's method's class with the Context's temporaries as its
  variables), **restart** a frame (8b's open question 3, the frame
  restart primitive, needed here), **step** (into, over, out: the
  interpreter needs a single-step mode for one Process, a per-Process
  flag the poll checks, out of the hot path; design and measure it;
  **owner**: is stepping in the first version, or restart and resume
  enough?), proceed, terminate.
- **Fix and continue**: compile the method in the stopped frame (8d),
  restart the frame on the new method.
- **The UI thread**: a stopped main-affine Process on the phone must not
  freeze the app. The debugger runs in the developer UI on the Mac, the
  stopped Process just sits; the shell's event loop and other Processes
  continue (ADR 0004's budgeted preemption already lets them).

## 3. Sources, files and git

8e makes the image the editor's model and writes Tonel. The project the
developer edits is a directory of Tonel files on the Mac (like `kernel/`,
and `apps/Shared/smalltalk`), under git, with the image built from it by
`kajo build-image`. Provisional rules:

- The target image's sources are the truth while it runs; the protocol's
  `sources.write` writes the changed classes to the project directory on
  the Mac (the developer UI's side, not the phone's), so a `git diff`
  shows what the session changed and the developer or the agent commits.
- The developer UI shows the image, not the files; the files are an
  export the UI keeps current after each successful compile (**owner**:
  write on every compile, or on demand?).
- A rebuilt image from the files equals the edited image method for
  method (8e's round-trip test extended to a project directory).

## 4. The developer UI

**owner**, the largest decision: **is the developer UI written in
Smalltalk, running in its own Kajo image in the macOS shell** (ADR 0010's
wrappers grown to a code browser, an inspector, a debugger, a test
runner, a transcript), **or in Swift and AppKit** against the protocol?

- Smalltalk: Kajo develops Kajo, the UI is itself live and debuggable
  with the same tools, the wrappers get a real workload, and the owner's
  "Smalltalk developer UI" reads literally. Cost: ADR 0010's widget set
  is six views; a browser needs lists, trees, text editing with
  selection, split panes, menus and keyboard handling, so 9b builds a
  second round of wrappers first, and a Smalltalk text editor.
- Swift: faster to a usable browser with AppKit's real text views and
  outlines; the UI is not live; two codebases to keep in step with the
  protocol.
- Provisional, if you do not say: Smalltalk, with AppKit's NSTextView
  and NSOutlineView wrapped rather than reimplemented (the wrappers hide
  the toolkit, so the editor stays native and the UI stays Smalltalk).

The first UI: a **browser** (classes by category, selectors, source,
compile on save), an **inspector**, a **debugger** on `process.stopped`,
a **test runner**, a **transcript**, a **workspace** (evaluate), and a
**target picker** (the local image, the Mac shell, the phone over the
transport). Each is a window; module 9a's one-Process event loop and the
hop rule stay.

## 5. The agent interface

AGENTS.md's use case names "AI agent integration". Provisional:

- The agent speaks the same protocol, through an **MCP server** the
  `kajo` CLI hosts (`kajo mcp --target ...`): tools for every protocol
  request (browse, compile, define, evaluate, inspect, run tests, read a
  stopped Process, restart, write sources), with the target's events
  streamed as the tool results' context. The developer UI shows what the
  agent does as it does it (the same events), and the agent sees what
  the developer does. **owner**: MCP, a plain CLI (`kajo eval`, `kajo
  compile`), or both? Provisional: both, the CLI over the same client
  code, since an agent in a terminal and an agent in an IDE differ only
  there.
- **What an agent may never do** is enforced in the target, not in the
  client: nothing in a release image; no file writes outside the project
  directory (8e's rule); no protocol without the token. Provisional: the
  same rights as the developer otherwise; **owner**: should an agent's
  installs be marked (a `<by: agent>` pragma or a source note) so the
  developer can see what the agent changed in the browser and in `git
  diff`?

## 6. The transport to the phone

**owner**, with a provisional answer: a TCP listener in the iOS shell on
the local network (Bonjour-advertised, token-paired, development images
only), because `devicectl` offers process launch and file copy but no
stream to a running app, and USB networking from a Mac to an iPhone needs
a tunnel Apple does not expose. The Mac shell and `kajo run` listen on a
Unix socket. If you want USB only, the fallback is the app writing and
reading files in its Documents through `devicectl device copy`, which is
polling, slow, and good enough for an agent but not for a debugger.

## What comes first (the build's order, provisional)

1. The protocol Process, the vocabulary over 8b to 8e, the Unix-socket
   transport, `kajo` CLI clients, tests against a headless target.
2. The debugger's target side: stop on error, Contexts, evaluate in a
   Context, restart (the primitive), proceed; tests headless.
3. The developer UI's first windows against the local target.
4. The MCP server and the CLI for agents.
5. The phone transport and the token; the first remote session recorded
   as a measurement (round trip of a compile, of a debugger step).
6. Stepping, if in.

## Deliverables, when started

The code and tests; `docs/modules/development-protocol.md` as built; an
ADR for the protocol (form, vocabulary discovery, the stop-on-error rule,
the token) and one for the developer UI's language if Smalltalk; ADR 0004
amended where the debugger lands; CONTEXT.md terms; the rules the agent
interface enforces written in AGENTS.md by the main session.

## Questions for the owner, in one list

1. Developer UI in Smalltalk (Kajo in Kajo) or in Swift?
2. Phone transport: TCP on the local network with a pairing token, or
   USB only via file copy?
3. Agent interface: MCP server, CLI, or both? Should an agent's changes
   be marked?
4. Debugger scope for the first version: stop on error, inspect, evaluate
   in a Context, restart, proceed; stepping too?
5. Should a stopped Process without a client time out, and should a
   release image ever stop a Process instead of terminating it?
6. Sources written to the project directory on every compile or on
   demand?
