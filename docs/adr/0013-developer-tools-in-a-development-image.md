# ADR 0013: The developer tools are a package of a development image, a client of the protocol

Date: 2026-11-05
Status: proposed (module 9c, `docs/modules/developer-ui.md`)

## Context

The owner decided on 2026-11-04 that every developer tool is Smalltalk
and Swift is the compiler and the bindings. Module 9b built the
development protocol (ADR 0011) with a Swift client for the CLI and the
agent; module 9c builds the developer UI: a browser, a workspace, an
inspector, a debugger, a test runner, a transcript and a target picker,
in Smalltalk, over native views (ADR 0010), in the macOS shell. Three
questions every later tool inherits: where the tools' code lives and
which images carry it, how a tool in an image reaches a target (another
image, the phone after 9d, or its own image), and what happens when a
tool's own code fails, since the tools run on the UI's one event loop
(ADR 0004).

## Decision

- **The tools are a package, `tools/` (package Tools), not part of the
  kernel.** A **development image** is `kernel/` and `tools/`
  (`kajo build-image --with tools`, `just dev-image`); any other package
  can be added the same way (`--with <dir>`, repeatable). An app's
  release image never carries `tools/`; the release flag is orthogonal.
  The tools' sources are in the canonical form the image writes
  (`scripts/canonical-tonel.sh`), and the round-trip test writes both
  packages of a development image back into their own directories, byte
  for byte.
- **A tool is a client of the protocol, always.** Every tool talks to its
  target through `DevClient`, whose requests are messages (one per
  request of `protocol.describe`) and whose replies and events arrive on
  the UI's event loop like a click. Even when the target is the image the
  tools run in (the **local target**: the development image serves its
  own protocol and its tools connect to that socket), the tools speak the
  protocol; they never reach into `DevSession` or `Debugger` directly. So
  a tool works unchanged against another image on the Mac or the phone,
  and the local target exercises exactly what a remote one would.
- **The host owns the socket; the image never sees a token.** The client
  transport is one primitive (164, `ClientTransport`) to the host's
  `ClientHost`: connect, send, close, list the targets, ask for a timer
  event. The host opens the session with the token it holds (its own
  transport's, or `~/.kajo/targets`'), reads every line with the bounded
  JSON reader, hands the image the canonical text of what it accepted or
  a `client.error` saying why not (never a trap), and posts lines and the
  connection's end on 9a's event queue. A line longer than one heap
  object can be (32 KiB) arrives in pieces. Timeouts are timer events,
  never waits in the UI.
- **A tool's error stops only its own Process.** While the protocol
  serves (the debugger is enabled), an error in an event handler makes
  the event loop hand itself over to a new loop Process and lets the
  erring one stop for the debugger; the `process.stopped` event then
  opens a debugger in the tools, which keep running. When the stopped
  Process is let go it finishes its event and ends.
- **Every window has a model tested headless.** What a tool shows and
  asks its target is a model object (`BrowserModel`, `DebuggerModel`,
  ...) tested in SUnit with a `FakeDevClient`; its window only turns the
  model's changes into view calls and the views' events into the model's
  actions.

## Reasons

- A package keeps the kernel the same for every app and the tools out of
  release images, with the same Tonel, package and author machinery 9b
  built for applications; nothing new was needed for the tools to be
  developed with the tools (their changes are written to `tools/` by the
  client's transport).
- One path to every target is the only way the phone target (9d) gets the
  same tools without a second implementation, and testing the tools on
  the local target tests the protocol they will use there.
- A token in the image would be written to every snapshot of it; the
  host already holds the transport's.
- The hand-over is the classic Smalltalk answer to "the UI Process hit an
  error": a debugger on the UI's own Process would freeze the UI that
  shows it.

## Costs and open problems

- **Objects larger than one block do not exist.** A reply of the
  2000-class browser (`class.hierarchy`, 190 KB; `package.selectors`,
  20 000 selectors) is longer than any String the image can hold, and the
  kernel's growable collections stopped at 2048 (OrderedCollection) or
  1535 (hashed) elements, so a 2000-class image could not even be built.
  Module 9c split lines into pieces both ways and gave the kernel a
  `LargeArray` the growable collections use past one object; a VM-level
  answer (large objects) is the owner's question.
- The local target's tools and the code they debug share one image: a
  tool that corrupts the image (a bad method in `BrowserModel`) breaks
  the tools; the remedy is a second development image as the target.
- Request round trips on the Mac are milliseconds; on the phone they will
  be the network's (9d), so every tool already waits for replies by
  callback.

## Consequences

- `tools/` (27 classes: 19 of the tools, `FakeDevClient` and seven SUnit test classes beside them), `kajo
  build-image --with`, `just dev-image`, `just tools`, the macOS shell's
  `mode=dev` and `mode=devsession`.
- Primitive 164 and `ShellCallbacks.client`; `KajoDev.ClientHost`; event
  kinds 7 to 16.
- `UIEventLoop` hands over on an error while the debugger is enabled.
