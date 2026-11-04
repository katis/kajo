# Module 9c: the developer UI in Smalltalk

Status: brief, 2026-11-05, from the owner's decision of 2026-11-04 ("I do
want the development tools to be Smalltalk too. Swift is for the compiler
and bindings") and module 9b's "What 9c needs" list
(`docs/modules/development-protocol.md`). Builds on 9a's shells and view
wrappers (ADR 0010, accepted), 9b's protocol and debugger (ADRs 0011 and
0012, proposed), 8e's live classes and Tonel. AGENTS.md's first use case
is this module's: a Smalltalk developer UI on the Mac that develops an
app live, locally now and on the phone after 9d.

## What it hides

- How a developer sees and changes a running image: a browser, an
  inspector, a debugger, a workspace, a test runner, a transcript, each a
  window of Smalltalk objects over native views, speaking the protocol to
  a target.
- Which target: the developer image itself (Kajo develops Kajo), another
  image on this Mac (`kajo run --protocol`, the Mac shell), and after 9d
  the phone; the UI does not know the difference.
- Where the tools' own sources live and how they get into an image.

## 1. The tools are a package, not part of every image

- The tools' sources live in `tools/`, Tonel files of package `Tools`
  (9b's package per method; a class's package is its file's directory),
  with their SUnit tests beside them, like `kernel/`. `kajo build-image`
  gains `--with <dir>` (repeatable): the image is built from `kernel/`
  plus each directory, every class recording its package. A **development
  image** is `kernel/` plus `tools/`; an app's release image never carries
  `tools/` (the release flag is orthogonal; a release image with tools is
  allowed but pointless). The round-trip test (8e, 9b) covers a build with
  two directories: each class is written back into its own directory,
  byte-identical.
- The macOS shell runs a development image when given one; the Mac shell
  is the developer UI's host. Nothing in the iOS shell changes here.

## 2. The protocol client in the image

9b's client is Swift (`KajoDev`); the UI is Smalltalk and needs to speak
the protocol from inside the image.

- **A client transport primitive** (the shell's side in Swift, as 9a's hop
  primitive: the shell owns the socket): connect to a target (a Unix
  socket path and a token), send a line, and receive replies and events
  as `ShellEvent`s on 9a's event queue, so the UI's one-Process event loop
  handles a reply like a click. Several targets at once (one connection
  each). In `kajo run` and in tests the same primitive exists so the
  client can be tested headless against a headless target.
- **`DevClient`** in the `Tools` package: requests as messages (one method
  per 9b request, generated from `protocol.describe` or written by hand
  with a test that compares the two), replies as objects, events
  dispatched to whichever window registered for them (`process.stopped`
  opens or focuses a debugger; `transcript` appends; `test.*` updates a
  runner). Request ids, timeouts as events (not wall-clock waits in the
  UI), a connection lost event.
- **The local target**: the development image serves the protocol itself
  (9b's Mac shell `protocol=`) and the UI connects to its own socket, so
  the tools can be developed with the tools. A stopped Process in the
  developer image (an error in the UI code) opens a debugger in the same
  image: the UI's event loop keeps running because 9b stops only the
  erring Process. Test this: an error thrown in a browser action stops
  that Process, a debugger opens on it, fix and proceed, the browser
  continues.

## 3. The second round of view wrappers (ADR 0010's design)

Through the one hop primitive and the handle table, new ops for:

- **TextView**: multi-line editing with selection (get, set, range),
  range attributes (colour, bold, background, for syntax colouring and the
  debugger's current-range highlight), key events before the view handles
  them (so the UI binds Cmd-S to save and Cmd-D to doit), text-changed
  events, read-only mode, a monospace font, line and column from an
  offset and back. AppKit's `NSTextView` (and `UITextView` on iOS, built
  but exercised only by the tests on the simulator-free gate `just apps`).
- **OutlineView** (tree) and **TableView** (list, columns): items supplied
  by the Smalltalk side on demand (a data-source protocol over the hop:
  the view asks for the children of an item by handle, the Smalltalk side
  answers; or the Smalltalk side pushes the whole tree; choose by
  measuring a 2000-class browser), selection events, double click,
  keyboard navigation.
- **SplitView**, **ScrollView**, **Toolbar**, **Menu** (the app menu bar
  and context menus, with key equivalents) and **Window** additions
  (title, close event, size and position saved by the Smalltalk side).
- The wrappers stay thin: every op hops once, no state the toolkit already
  holds is mirrored in Smalltalk unless measured to be needed. ADR 0010
  gains a Built (9c) note; if the data-source form needs a callback from
  the toolkit into Smalltalk (the view asks), design how a toolkit
  callback becomes a hop-safe event and document it in the ADR.

## 4. The windows

Each is a Smalltalk class in `Tools` over the wrappers and `DevClient`:

- **Browser**: packages, classes (hierarchical or by category, toggle),
  class side / instance side, categories, selectors, the source with
  syntax colouring (the kernel's Scanner), compile on Cmd-S with errors
  shown at their range, class definition and comment editing, senders and
  implementors, remove class or method, define a class from a template.
  Every change goes through the protocol and the files are written to the
  project (9b's `files` in the reply, written by the client primitive to
  `--project`; on the local target, the development image's own
  directory).
- **Workspace**: evaluate a selection (Cmd-D), print it (Cmd-P), inspect
  it (Cmd-I).
- **Inspector**: an object's slots, printString, a workspace pane with
  `self` bound, dive into a slot; handles released when the window closes.
- **Debugger**: opens on `process.stopped`: the frames, the source of the
  selected frame with the current range highlighted, its variables, a
  workspace pane in the frame's context; buttons proceed, restart, retry
  send, step into / over / out, terminate; edit the method in the frame
  and save (fix and continue); "define the method" on a
  doesNotUnderstand: stop (the 9b trick: it opens the browser on the
  receiver's class with a template, and retry-send on save).
- **Test runner**: classes and selectors, run, the `test.*` events as they
  arrive, failures open a debugger when asked.
- **Transcript**: the `transcript` events of every connected target.
- **Target picker**: the known targets (the local image; sockets and
  tokens entered or found in a `~/.kajo/targets` file the shell reads;
  9d adds the phone), connect and disconnect, the connection state in a
  status bar.

## 5. Measurements

- **Typing latency** in the browser's text view: key event to the redraw
  that shows it, p50 and p99, on the Mac mini's 120 Hz display, with the
  local target running the storm scenario in another Process; frames
  missed by the UI's own display link across a scripted session.
- **A scripted session** (9a's scenario machinery, `just mac-shell`): open
  the browser on a 2000-class image (make one), select classes and
  methods, compile a method, run a test class, trigger an error, debugger
  opens, step twice, fix and proceed; frames missed, request latencies,
  memory of the developer image. This scenario is the module's gate on
  the Mac shell.
- **Browser population**: time to list 2000 classes and 20 000 selectors,
  for the data-source form chosen and the alternative.

## Rules

Those of AGENTS.md. The UI runs under 9a's rules: one event-loop Process,
the hop rule, the frame budget; nothing of the UI touches the interpreter.
The wrappers' Swift is binding code only (the owner's rule): no tool logic
in Swift. The developer image's sources are written to `tools/` by the
tools themselves, through the protocol, and the canonical form holds
(write out of the image, copy back, round-trip test green). Every window
is testable headless: its model (what it shows, what it asks the client)
is a Smalltalk object tested with a fake client in SUnit; the views are
tested in the Mac shell's scenario.

## Deliverables

The code and tests; this file as built; ADR 0010 Built (9c) note (and a
decision on the data-source form); an ADR for the tools-as-a-package rule
and the development image if it needs one; CONTEXT.md terms; `justfile`
recipes (`just dev-image`, `just tools`: build the development image and
open the Mac shell on it); the 9d brief's needs (what the phone target
must provide beyond the socket).

## Not in this module

The phone transport (9d). Method versions and a changes log (a later
module; 9b listed it as a likely request). Refactorings (rename, extract).
Keyboard-driven everything: menus and shortcuts for the listed actions,
not a complete keymap.
