# Module 9c: the developer UI in Smalltalk

Status: built, 2026-11-05, from the brief of the same day (the owner's
decision of 2026-11-04: "I do want the development tools to be Smalltalk
too. Swift is for the compiler and bindings", and module 9b's "What 9c
needs"). Builds on 9a's shells and view wrappers (ADR 0010, accepted),
9b's protocol and debugger (ADRs 0011 and 0012, proposed), 8e's live
classes and Tonel. Module 9 is four builds: 9a (the shells), 9b (the
protocol and the debugger), **9c (this)**, the developer UI, and 9d, the
phone's transport ("What 9d needs", below).

New: `tools/` (package Tools: 27 classes, 19 of the tools, the test
client `FakeDevClient` and seven SUnit test classes, 3200 lines), the
client transport (primitive 164, `kernel/ClientTransport`,
`Sources/KajoDev/ClientHost.swift`), the second round of view wrappers
(`kernel/`: `TextView` again, `OutlineView`, `TableView`, `SplitView`,
`ScrollView`, `Toolbar`, `Menu`; AppKit in
`apps/KajoShell-macOS/Sources/DevViews.swift`, UIKit's text view in
`IOSShell.swift`, what both share in
`Sources/KajoShellCore/TextOffsets.swift`; since module 11a these are
`Sources/KajoApp/AppKitViews.swift`, `UIKitHost.swift` and
`TextOffsets.swift`, `docs/modules/app-project.md`), `kernel/LargeArray`,
`JsonText` and `JsonPieceStream` (objects and lines longer than one heap
block, section 5), the macOS shell's `mode=dev` and `mode=devsession`
(`Sources/KajoShellCore/DevModes.swift`), the scripted session
`apps/Shared/devsession/DevSessionBench.class.st`, `kajo build-image
--with`, `just dev-image` and `just tools`, `scripts/canonical-tonel.sh`,
`scripts/gen-classes.py`, `scripts/devsession-report.py`, ADR 0013
(proposed). Tests: `Tests/KajoCompilerTests/ToolsTests.swift` with the
fixture `Fixtures/toolsprobe/`, the tools' SUnit tests, `kernel/ViewWrapperTest`
and `kernel/LargeArrayTest`.

## What it hides

- How a developer sees and changes a running image: a browser, a
  workspace, an inspector, a debugger, a test runner, a transcript and a
  target picker, each a model of Smalltalk objects and a window of native
  views, speaking the protocol to a target through `DevClient`.
- Which target: the development image itself (the **local target**: it
  serves its own protocol and its tools connect to it), another image on
  this Mac (`kajo run --protocol`, the Mac shell, `~/.kajo/targets`), the
  phone after 9d. The tools do not know the difference: they always speak
  the protocol.
- Where the tools' sources live (`tools/`, package Tools) and how they get
  into an image (`kajo build-image --with tools`).
- That no object is larger than one heap block: replies, events and lines
  longer than 32 KiB, and collections longer than 4095 elements, travel and
  live in pieces.

## 1. The tools are a package

`tools/` holds the tools as Tonel files of package Tools (the directory's
name capitalized, 9b's rule), their SUnit tests beside them, in the
canonical form the image writes. `kajo build-image --with <dir>`
(repeatable) adds a package directory to `kernel/` (or to the directories
named): a **development image** is `kernel/ --with tools` (`just
dev-image` writes `dev.img`), every class recording its package. An app's
release image never carries `tools/`. `Smalltalk writePackages:` writes
several packages each into its own directory;
`ToolsTests>>bothPackagesAreWrittenBackByteForByte` writes a development
image's Kernel and Tools into `kernel/` and `tools/` and finds every file
byte for byte the one it was built from. `scripts/canonical-tonel.sh` does
the same against the working tree and copies back what differs: how the
files written by hand here were put into the canonical form, as 8e did
(`--check` only lists).

The macOS shell runs a development image in `mode=dev` (`image=`, default
the bundled `dev.img`; `project=`, where the tools' changes to the local
target are written): it serves the protocol on a socket, adds the socket
and its token to the client transport's targets as `local`, reads
`~/.kajo/targets`, and runs `DevTools openLocal:project:` on main. `just
tools` builds `dev.img` from the working tree and opens it with
`project=$PWD/tools`: changes the tools make to themselves are written
into `tools/` by the tools, through the protocol (a change to a kernel
class becomes Tools' `<Class>.extension.st`, 9b's rule). The iOS shell
changes only its text view (section 3).

## 2. The protocol client in the image

### The client transport (primitive 164)

`ClientTransport class >> primCall: op handle: h with: args` (primitive
164) carries an op, a connection handle and plain values to the host's
`ShellCallbacks.client`, on any worker, in a blocking region (it touches
no heap object), like 9a's view primitive but not a hop: the host owns the
sockets. `KajoDev.ClientHost` implements it in the macOS shell
(`ShellRuntime`) and in the tests:

| op | arguments | what |
|---|---|---|
| `targets` | | the known targets, a line `name TAB path TAB 1/0` each (whether the host holds the token) |
| `connect` | path, client, package, token, project | a new connection's handle at once; the connect and `session.open` run on a thread of its own |
| `send` | (handle) line | one request line, written in order (lines sent before the session opened wait for it) |
| `close` | (handle) | |
| `timer` | ms, token | a `timer` event with that target after ms |

What a connection receives is trusted for nothing: every line goes
through 9b's bounded JSON reader (`ClientHost.check`: 64 MiB, depth 64, a
million elements) and the image gets the canonical text of the object it
read, or a `client.error` object naming why (not JSON, not an object, too
long); never a trap. Lines arrive as **`line` events** on 9a's event
queue (target the connection); a line longer than 16 KiB as `linePart`
events of at most 16 KiB cut between scalars, then the `line` event with
the last piece (no String of the image can pass one heap block; since the
large-bytes follow-up a line arrives as one String up to 16 MiB - 1,
measured cheaper for the image, and only a longer one in pieces of that
size: docs/modules/large-bytes.md, part 3); the end
of the connection is a **`lost` event** with the reason. When the
connection was opened with a project directory, the `files` of every
reply are written there by 9b's `ProjectWriter` (file names only), as the
CLI does. **The token never enters the image**: `connect` names the
socket, and the host opens the session with the token it holds for that
path (its own transport's for `local`, or `~/.kajo/targets`'), unless the
developer typed one into the target picker. `ProtocolServer`, `ClientHost`
and its targets reflect without their tokens (a failed expectation in a
test printed one before that). `just fuzz protocol` runs every line
through `ClientHost.check` and its pieces too.

### `DevClient`

One `DevClient` per connected target (`DevClient
connect:name:client:package:token:project:`):

- **Requests are messages**, one per request of `protocol.describe`
  (`classHierarchy:`, `methodCompile:source:category:side:then:`, ...),
  each taking the request's arguments and a block that gets the result.
  `DevClient class >> requests` maps every kind to its method;
  `DevClientTest>>testEveryRequestHasItsMessage` checks the map against
  the image's own `DevProtocol describe`: the same kinds, each method
  taking the request's arguments and the block. The generic
  `request:args:then:else:` takes an error block; the tools' models use it
  so a request's error reaches the window that sent it.
- **Replies are objects** (the JSON reader's JsonObjects, Arrays,
  Strings, numbers), matched by id; the round trip of each, from the send
  to the reply's dispatch in the event loop, is kept for the measurements.
- **Events go to whoever registered** for their kind (`on:
  'process.stopped' do:`, `'*'` for all): `process.stopped` opens or
  brings back a debugger (`DevTools`), `transcript` appends to the
  transcript, `test.*` update a runner. The client's own:
  `connection.open` (the session's reply), `connection.refused`,
  `connection.lost`, `client.error`.
- **Timeouts are events**: every request asks for a timer event
  (`UIEventLoop after:do:`, 30 s); one that fires before the reply fails
  the request. The connection's end fails every pending request.

The event loop gives `line`, `linePart` and `lost` events to the client of
their connection (`UIEventLoop on: #line do:`: the loop's actions by
kind), so the UI's one event loop handles a reply like a click.

### The local target, and an error in a tool

The development image serves its own protocol and its tools connect to
that socket: Kajo develops Kajo through the same requests a remote target
gets. While the protocol serves, an unhandled error stops its Process for
the debugger (9b). The tools run in the event loop's Process, so an error
in a tool would stop the event loop itself, and nothing could then show
the debugger. `UIEventLoop dispatch:` therefore, while the debugger is
enabled and the erring Process is the loop's, **hands the loop over**: a
new loop Process (a new generation) takes the events from now on and the
error is passed on, so the old Process stops for the debugger
(`UIEventLoop handOverCount`). The `process.stopped` event reaches the
tools' own connection, the new loop dispatches it and a debugger opens on
the stopped Process; when the debugger lets it go on, it finishes its
event and ends (its generation is no longer the loop's). Without the
protocol the error goes to the Transcript as in 9a.

`ToolsTests>>anErrorInAToolStopsOnlyItsProcessAndTheToolsGoOn`: in a test
shell serving its own protocol with the real client transport, a menu
action of the browser sends a message nothing understands; the event
loop's Process stops, a new one takes over (one hand-over, another Process
id), a debugger opens on the stop with its frames; "define the method" in
the debugger opens a browser on the receiver's class with a template;
accepting it compiles the method (its file lands in the project directory)
and retries the send; the action finishes (the probe sees 42), and the
next menu action runs in the new loop.

## 3. The second round of view wrappers (ADR 0010)

Through the one hop primitive (150) and the handle table; every op hops
once and nothing the toolkit holds is mirrored in Smalltalk (the text
lives in the text view; the selection is asked for when needed):

| wrapper | ops | events |
|---|---|---|
| `TextView` (9a's, now an editor) | `set editable`, `set keys` (reported before the view handles them: `cmd-s`), `get selection`, `call select start stop`, `call setStyles` ({start. stop. style} triples: `color:<name>`, `background:<name>`, `bold`), `call scrollTo`, `call focus`; a monospace font; line and column from an offset and back in Smalltalk | `key` (its name), `textChanged` |
| `OutlineView` | `call setChildren parent (id title expandable)*`, `addChildren`, `call setTree (id parent title)*`, `addTree`, `expand`, `expandAll`, `select`, `get selected` | `selectionChanged`, `doubleClick`, `expand` (an item whose children were not given) |
| `TableView` | `call setColumns`, `call setRows cols cells*`, `addRows`, `call setRowCount n`, `call setRowsAt first cols cells*`, `selectRow`, `get selected` | `selectionChanged`, `doubleClick`, `expand` (the first row of a page the table needs) |
| `SplitView` | `set vertical`, `add` (a pane), `call setPosition divider points` | |
| `ScrollView` | `add` (to what scrolls), `set contentWidth`, `contentHeight` | |
| `Toolbar` | `call addItem id title`; `Window>>toolbar:` (`call setToolbar`) | `menu` (the item's id) |
| `Menu` | `call addItem id title key` (`cmd-shift-t`), `call addSubmenu`, `call install` (the menu bar), `View>>contextMenu:` (`call setMenu`) | `menu` (the item's id) |
| every view | `set autoresize` (`width height`, `left top`: which edges follow the superview) | |
| `Window` | `frame` reads its position on the screen and its size (y down from the top of the visible frame, what the frame op takes) | `close` (9a) |

Positions in a String are the kernel's: 1-based UTF-8 byte offsets, a
range start to stop inclusive; the shells convert to and from their UTF-16
`NSRange`s at scalar boundaries (`TextOffsets`) and refuse a range that is
not one. An Array argument holds at most 4095 values (one heap object), so
`children:of:`, `tree:` and `rows:` send pages (1300 items, 4000 cells) as
`set...` then `add...` calls. Selection changes the image makes do not come
back as events (the shell's data sources are quiet while they change).

**The data-source form** (the brief: "choose by measuring a 2000-class
browser"). The toolkit's data source asks synchronously, inside AppKit,
for an item's children; the hop rule forbids calling into the VM there, so
a toolkit callback becomes an event: the shell's data source holds the
items it was given, and when the view needs ones it was not given (an
item expanded, a page of rows scrolled into view) it posts an `expand`
event and shows them when the image sends them. That gives two forms
behind the same wrappers, **push** (everything in one or a few calls) and
**on demand** (the roots or a row count, then what the view asks for).
Measured over four gate attempts (Measurements, Browser population): the 2000-class tree in 50 to 91 ms pushed and 49 to 82 ms on demand, the request (0.3 s) most of the population either way; a table of 19 866 rows in 68 to 117 ms pushed and 10 to 18 ms on demand. **The tools push**: a programmatic selection (the
browser going to a class from a senders list) needs the item in the data
source, and the lists the tools show are a class's or a package's, small
next to a page. The on-demand form stays built and measured for long
lists (ADR 0010's Built (9c) note).

AppKit: an `NSTextView` subclass (`KajoTextView`) that reports the bound
keys in `performKeyEquivalent:` and `keyDown:` before handling them, posts
`textChanged` from its delegate and tells the shell when it drew (the
typing measurement); `NSOutlineView` and `NSTableView` over data sources
holding what they were given; `NSSplitView`; `NSScrollView` with a flipped
document view; `NSToolbar` with a delegate; `NSMenu` items with key
equivalents in the menu bar or as a view's menu. UIKit: the text view's
editable mode, selection, styles, scroll, focus and change event on
`UITextView`; the other kinds are the Mac's for now (the iOS shell is
built by `just apps`, not exercised).

**A view call can take milliseconds.** 9a's turn ends at a budget checked
every 1024 polls, nanoseconds of sends apart; a turn building a window
makes tens of view calls of up to 14 ms of AppKit (a toolbar set on a
window), and the scripted session had a turn of 40 ms in one slice. The
hop primitive now sets the countdown to 1 when a view call on main ends
past the turn's deadline, so the next poll checks the budget: the longest
turn of the session went from 39 to 44 ms to 13 to 16 ms. Nothing of this
is on the interpreter's paths (the primitive is out of line from
`primitive`).

## 4. The windows

Each tool is a model (`ToolModel`: a client, the window or nil, a status
line; `changed:` aspects) and a window (`ToolWindow`: native views built
in `build`, refreshed in `update:`, the views' events bound to the model's
actions). The models are tested in SUnit with `FakeDevClient` (requests
answered at once by a block, events given by hand); the windows build
headless too (the wrappers keep their properties without a shell), and
`ToolWindowTest` checks the browser's and the debugger's.

- **Browser** (`BrowserModel`, `BrowserWindow`): packages, the class tree
  by superclass or by category (toggle), the instance or class side,
  method categories and selectors in a split view over the source pane, a
  toolbar (side, tree form, definition, comment, new method, new class,
  senders, implementors, remove method, remove class) and a context menu on
  the selectors. The source is coloured as it is edited (`SourceColorer`
  over the kernel's Scanner: the message pattern bold, pseudo-variables
  teal, globals purple, literals brown and green, comments gray); Cmd-S
  accepts it: a method is compiled (`method.compile`), a class definition
  (`Super subclass: #Name instanceVariableNames: '...' classVariableNames:
  '...' category: '...'`, read with the Scanner) defined (`class.define`),
  a comment set (`class.comment`); a compile error's line is marked red.
  Senders and implementors open a list; double-clicking one goes there.
  The class tree comes from one request (`class.hierarchy`, added).
- **Workspace**: Cmd-D evaluates the selection or the line (`evaluate`),
  Cmd-P prints its value after it, Cmd-I inspects it.
- **Inspector**: the object's slots (name, class, value), its printString,
  a workspace with self bound to it (its handle); double-click a slot to
  dive, Back to return; every handle it was given is released when the
  window closes (`inspect.release`).
- **Debugger**: opens on `process.stopped`, or comes back for the same
  Process: a toolbar (proceed, restart, retry send, into, over, out,
  terminate, define method), the frames, the selected frame's source with
  the range its pc is at highlighted and scrolled to, its variables, a
  workspace evaluating in the frame (`process.evaluate`). Cmd-S in the
  source saves the frame's method and restarts the frame (fix and
  continue). At a doesNotUnderstand: stop, "define method" opens a browser
  on the receiver's class with a template, and accepting it retries the
  send.
- **Test runner**: the target's TestCase classes (from the class tree),
  run the selected one or all (`test.run`), the `test.*` events as they
  arrive, the counts; Debug runs a failure again without SUnit's handler
  (`(Foo selector: #testBar) runCase` evaluated), so it stops for the
  debugger.
- **Transcript**: the `transcript` events of every connected target, each
  line marked with its target when more than one is connected.
- **Target picker**: the targets the shell knows and those entered (a
  socket and a token), connect and disconnect, the state of each and a
  status bar with the last change.
- **DevTools**: the targets' clients by name, the open windows, a Tools
  menu in the menu bar (Browser Cmd-B, Workspace Cmd-K, Test Runner
  Cmd-U, Transcript Cmd-J, Targets Cmd-Shift-T); a window opens where the
  last of its kind was closed (the frames are kept in the image).

`ToolsTests>>theToolsDevelopTheImageTheyRunIn` opens the tools on the
image's own socket in a test shell, compiles a method into the running
image through the browser and finds its file in the project directory.

## 5. Objects longer than one heap block

No object is larger than one heap block (32 KiB: 4095 slots, 32 760
bytes; AGENTS.md's 8b lesson). 9b never met it; the 2000-class browser
meets it at every layer:

- **The kernel could not hold 2000 classes.** `OrderedCollection` grows by
  doubling and stopped at 2048 elements, the hashed collections at 1535 (a
  rehash to 4096 slots fails), so `Smalltalk allBehaviors` (two per class)
  and the image's tables by behavior failed past about 760 classes: the
  image build of 800 classes or more died in `recordDefinitions:` (the
  error's report overflowed the stack). **`LargeArray`**: a sequence of
  Arrays of 2048, indexed from 1; `Array large: n` answers an Array when n
  fits one object and a LargeArray otherwise, and `OrderedCollection` and
  `HashedCollection` allocate with it, so their tables pass one object
  (`LargeArrayTest`: 10 000 elements, a Set and a Dictionary of 6 000). Its
  `at:` is a send, not the Array fast path, and only past 4095 slots.
- **The kernel's sort was an insertion sort**: 5.3 s for 5 000 reversed
  elements in a release build. `sort:` is now a stable merge sort (runs of
  8 by insertion; 32 ms for the same).
- **A reply longer than 32 KiB could not be written**: `Json write:` grows
  one ByteArray. `Json writePieces:` writes ByteArrays of 16 KiB
  (`JsonPieceStream`), `DevProtocol` writes every reply and event that way,
  and primitive 161 takes an Array of Strings and ByteArrays and joins them
  (still one line of valid UTF-8, at most 64 MiB). The client's transport
  hands a long line to the image in pieces, and `Json read:` reads an Array
  of pieces through `JsonText`. A result that cannot be written is now an
  error reply (it was no reply: the broken variant below found it).
- **A request longer than one heap block could not reach the image**
  (primitive 160 could not make its String, the protocol Process got nil
  and no reply ever came). The transport now refuses a request whose
  canonical text passes 32 704 bytes with an error reply
  (`ToolsTests>>aRequestTooLongForTheImageIsRefusedNotDropped`).

A large-object space in the VM would remove the cause; that is the
owner's question (below).

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS
27.2, its display a Samsung TV at 2560 x 1440 and 120 Hz (the display link
asks for 120 Hz only, Changes); swift.org Swift 6.4.2 for `kajo` and the
gates, Xcode 27.2 for the app (Release). The shell runs were the gate run's
(`just mac-shell run`, commit 2650aea, 2026-11-05 05:57 to 05:59, thermal nominal
throughout), three of each interleaved; medians, the range in brackets
(`scripts/devsession-report.py`; every result line is in the gate's files,
`mac-shell-devsession.results`).

### Typing latency

`mode=devsession classes=0 typing=200 load=storm|none`: a browser on a
method of the development image, 200 keys typed into its source pane at 20
per second (`NSEvent` key-downs sent to its window, as the window server
would deliver them). Each key's latency is from the key event to the end
of the text view's first draw after the image coloured the change: the
key goes to `NSTextView`, its delegate posts `textChanged`, the event loop
runs in the same run-loop turn, `BrowserWindow` reads the text and sets its
styles (one `setStyles` view call), and AppKit draws at the next display
refresh. With `load=storm` the image runs 9a's storm scenario on its five
background workers throughout (the local target is the image itself).

| load | key to redraw p50 ms | p99 ms | max ms | key to colours p50 ms | p99 ms | frames missed while typing (of) |
|---|--:|--:|--:|--:|--:|--:|
| storm (5 workers) | 2.3 [1.4–5.0] | 2.9 [2.7–5.1] | 7.4 [6.0–7.4] | 0.7 [0.7–0.9] | 2.3 [0.9–2.7] | 2 [1–18] (1258 [1242–1259]) |
| none | 5.5 [4.1–6.0] | 7.5 [6.1–8.1] | 16.0 [7.2–16.6] | 2.7 [2.5–3.0] | 5.8 [4.0–6.3] | 37 [35–170] (1223 [1090–1225]) |

- Every key was shown within one refresh with the storm (a refresh is 8.3
  ms; the max 6 to 7 ms) and all but one or two per run without (max 7 to
  17 ms); colouring the method takes under 1 ms at p50 with the storm and
  about 2.7 ms without (the main thread on slower clocks with nothing else
  running, as the frames below suggest). Across the four gate attempts the
  p50 ranged 1.4 to 7 ms: it is mostly where in the 8.3 ms refresh the key
  fell.
- **Without load the typing missed 35, 37 and 170 frames of 1259**, as
  two-frame gaps, while the image's turns stayed short (the longest 13.1
  to 14.3 ms, two or three over a frame per run): the misses are not the
  VM's turns. With the storm running, 1, 2 and 18. Earlier attempts gave 1
  to 211 without load and 0 to 6 with the storm. Not explained here; the
  idle machine's main thread on slower clocks (9a's phone note) is a
  guess, not a measurement. The first attempt, before the display link
  asked for 120 Hz only, had the link at 60 Hz for stretches (Changes).

### The scripted session

`mode=devsession classes=2000 load=none|storm`: the development image
with 1806 generated classes of 11 methods (`scripts/gen-classes.py`: 2009
classes, 22 284 methods, a 38 MB image) opened on its own socket; the
steps of `DevSessionBench`, each waiting for what the tools show (polled
by timer events) before the next: open the tools, populate the browser
twice (the class tree pushed, then on demand), the tree alone again in
each form, a package's 19 866 selectors in a table pushed and on demand,
ten classes and a method of each selected, a method compiled, `StringTest`
run, an error raised in a workspace doit that opens a debugger, two steps
over, and a fix saved in the frame (compiled and restarted). Frames are the
display link's across the whole session.

| load | seconds | frames (of expected) | missed | max gap ms | longest turn ms | peak footprint MB |
|---|--:|--:|--:|--:|--:|--:|
| none | 3.9 [3.9–4.0] | 434 [433–442] (468) | 32 [28–34] | 33.3 [29.7–36.0] | 13.4 [12.7–14.2] | 312 [309–316] |
| storm (5 workers) | 3.7 [3.7–3.8] | 420 [418–422] (450) | 26 [26–33] | 35.4 [28.9–36.7] | 15.1 [14.1–15.7] | 812 [811–817] |

Steps (ms, and the frames missed inside each):

| step | none ms | missed | storm ms | missed |
|---|--:|--:|--:|--:|
| open (the tools' session open, the first browser populated) | 387 [352–423] | 0 | 397 [392–397] | 0 |
| populate, tree pushed (`package.list`, `class.hierarchy`, the tree) | 384 [358–466] | 0 | 393 [385–398] | 0 |
| populate, tree on demand | 451 [368–476] | 0 | 383 [383–384] | 0 |
| the tree alone, pushed | 65 [58–91] | 0 | 59 [58–59] | 0 |
| the tree alone, on demand | 57 [50–82] | 0 | 57 [57–58] | 0 |
| `package.selectors` (19 866) | 706 [657–706] | 0 | 676 [672–678] | 0 |
| 19 866 rows pushed | 108 [76–117] | 3 [1–3] | 79 [78–81] | 1 [1–2] |
| 19 866 rows on demand (the count, the first page) | 15.3 [14.8–17.4] | 1 | 10.2 [10.2–10.6] | 0 |
| ten classes and a method each | 201 [179–220] | 4 [2–5] | 184 [180–194] | 1 [1–2] |
| compile a method | 15.6 [15.2–17.3] | 0 | 15.0 [14.9–16.0] | 0 |
| run `StringTest` | 21.8 [18.2–23.6] | 0 [0–1] | 25.0 [22.8–31.3] | 0 |
| an error, the debugger open with its frames | 401 [359–424] | 3 [2–4] | 375 [374–392] | 2 [2–4] |
| step over | 35.1 [33.6–41.9] | 1 | 35.2 [33.8–40.3] | 1 [0–1] |
| step over | 33.1 [25.2–33.4] | 1 [0–1] | 41.5 [33.3–41.8] | 1 [0–1] |
| save a fix in the frame (compile, restart) | 13.9 [12.5–14.1] | 0 [0–1] | 12.8 [12.0–13.0] | 0 [0–1] |

Request round trips over the session (from `DevClient`'s send to the
reply's dispatch in the event loop, through the image's own socket; count
per run, ms):

| request | count | none p50 | none max | storm p50 | storm max |
|---|--:|--:|--:|--:|--:|
| `class.hierarchy` (2009 classes) | 4 | 329 [311–330] | 360 [351–382] | 319 [318–331] | 342 [340–355] |
| `package.selectors` (19 866) | 2 | 657 [642–706] | 717 [706–749] | 671 [669–672] | 676 [672–678] |
| `package.list` | 3 | 8.5 [7.8–9.1] | 10.4 [9.0–10.4] | 11.1 [9.8–11.6] | 12.4 [9.9–12.6] |
| `class.selectors` | 12 | 4.2 [3.4–6.6] | 14.5 [14.1–17.8] | 3.4 [3.1–3.9] | 40.5 [8.8–52.1] |
| `class.definition` | 11 | 2.8 [2.2–3.1] | 10.0 [6.1–11.4] | 3.6 [2.8–4.1] | 10.1 [10.0–12.2] |
| `method.source` | 10 | 0.4 [0.4–0.5] | 13.9 [7.1–23.6] | 2.6 [1.8–3.2] | 9.2 [9.2–10.2] |
| `method.compile` | 2 | 0.9 [0.9–1.0] | 3.0 [2.7–6.0] | 4.4 [2.0–5.0] | 6.3 [4.5–7.2] |
| `test.run` (`StringTest`) | 1 | 9.6 [9.6–18.3] | | 18.1 [16.5–21.8] | |
| `evaluate` (the failing doit; its reply says it stopped) | 1 | 2.6 [0.6–8.8] | | 8.8 [5.1–8.9] | |
| `process.frames` | 3 | 17.3 [17.1–17.6] | 66.5 [57.1–73.4] | 25.6 [17.1–25.7] | 61.0 [60.2–75.7] |
| `process.step` | 2 | 5.9 [0.5–8.6] | 10.0 [7.1–11.2] | 6.4 [4.5–6.6] | 6.7 [6.6–6.9] |
| `process.restart` | 1 | 0.4 [0.3–0.6] | | 3.5 [2.9–3.5] | |

- **The missed frames are AppKit's, not the VM's.** 3 to 13 frames are
  missed inside the steps (window and table work: the debugger's window,
  the 19 866-row push); the rest, about 20, before the first step, while
  `DevTools openLocal:` opens the first three windows. The longest turn of
  the image on main is 12.7 to 15.7 ms in every run, after the view-call
  budget check (section 3); before it, 39 to 44 ms. The storm does not
  change the picture: its five workers allocate 800 MB while the UI keeps
  the same frames and request times.
- **The browser's population is the requests'**: `class.hierarchy` of
  2009 classes takes 0.29 to 0.33 s (2009 JSON objects made and written in
  pieces in the target, read back in 12 pieces of 16 KiB in the tools), the tree in the outline 50 to 77 ms in either form.
  `package.selectors` (19 866 methods, 0.6 to 0.7 s) is the slowest request
  of the session; a browser never asks it (the measurement's own).
- Memory: the development image with 2000 classes in the shell peaks at
  312 MB with no load (38 MB of image, the 1 GiB heap's working set, AppKit),
  812 MB with the storm's trees.

### Browser population

From the session's steps (no load, three runs): 2009 classes listed
(`class.hierarchy`) in 0.33 s, the tree pushed into the outline in 58 to 91 ms (two view calls of at most 1300 items) and on demand in 50 to 82 ms
(the roots, then each item's children as they are expanded); 19 866 selectors listed (`package.selectors`) in 0.66 to 0.71 s, into a table pushed in 76 to 117 ms (five calls of 4000 cells) and on demand in 15 to 17 ms (the row count and the first page of 100). Across the four gate attempts: the tree 50 to 91 ms pushed and 49 to 82 on demand, the table 68 to 117 ms pushed and 10 to 18 on demand. The
model's own work (`BrowserModel classTree` over 2009 entries) is 15 ms
after its class index by name (it was 9.5 s with a linear lookup per
class, the first measurement's).

### The kernels against the starting commit

The starting commit's `kajo` (4f83594, from a worktree) against this
module's (350d689; the VM has not changed since), both built `-c release
-Xswiftc -enable-testing` with `-align-all-nofallthru-blocks=5
-align-loops=32`; five runs interleaved, `--slice-ms 0`, 2026-11-05 01:40 to 01:51;
median (min to max) ms; every checksum equal on both sides and the
published one.

| kernel | workers | 4f83594 ms | 9c ms | 9c / start | checksum |
|---|--:|--:|--:|--:|---|
| alloc | 1 | 2963.9 (2950 to 2970) | 2946.6 (2929 to 2957) | **0.994** | 41950911 |
| alloc | 8 | 469.7 (444 to 544) | 462.7 (453 to 517) | **0.985** | 42008248 |
| arith | 1 | 2548.2 (2545 to 2554) | 2548.2 (2544 to 2560) | **1.000** | 372800000 |
| arith | 8 | 339.0 (337 to 360) | 349.3 (338 to 362) | **1.030** | 372800000 |
| fib | 1 | 1715.1 (1710 to 1718) | 1697.6 (1691 to 1701) | **0.990** | 24682992 |
| fib | 8 | 234.0 (219 to 245) | 222.5 (217 to 229) | **0.951** | 24682992 |
| ivars | 1 | 1969.0 (1967 to 1972) | 1969.9 (1966 to 1973) | **1.000** | 36383626 |
| ivars | 8 | 257.2 (252 to 271) | 262.8 (253 to 275) | **1.022** | 71714128 |
| sends | 1 | 2589.1 (2578 to 2599) | 2573.4 (2568 to 2591) | **0.994** | 1066666666666668 |
| sends | 8 | 344.7 (332 to 360) | 341.0 (331 to 354) | **0.989** | 133333335000001 |
| storeheavy | 1 | 2404.8 (2394 to 2409) | 2404.0 (2399 to 2413) | **1.000** | 512000 |
| storeheavy | 8 | 324.2 (309 to 330) | 315.4 (310 to 332) | **0.973** | 512000 |
| Smalltalk closures | 1 | 3813.1 (3811 to 3819) | 3794.9 (3789 to 3798) | **0.995** | 210210000 |
| Smalltalk closures | 8 | 514.1 (496 to 527) | 495.3 (483 to 511) | **0.963** | 209214000 |
| Smalltalk ivars | 1 | 1971.2 (1968 to 1978) | 1969.8 (1964 to 1974) | **0.999** | 36383626 |
| Smalltalk ivars | 8 | 257.4 (252 to 280) | 254.3 (252 to 278) | **0.988** | 71714128 |
| Smalltalk sends | 1 | 2327.1 (2326 to 2334) | 2323.6 (2295 to 2340) | **0.998** | 1066666666666668 |
| Smalltalk sends | 8 | 302.1 (296 to 318) | 313.8 (299 to 320) | **1.039** | 133333335000001 |

Within noise: 0.990 to 1.000 on one worker, 0.951 to 1.039 on eight with
overlapping ranges. `interpret` is the same code in both aligned binaries:
its disassembly (1320 lines) differs only in the page offsets of the jump
table's `adrp` (8 lines). Nothing of 9c is on the dispatch loop, the send
path or the poll; the Smalltalk kernels do not grow a collection past one
object or sort.

## Changes to earlier modules

- **9a**: `ShellEventKind` gains `key`, `selectionChanged`, `doubleClick`,
  `expand`, `menu`, `line`, `lost`, `timer`, `textChanged`, `linePart`
  (7 to 16; `UIEvent kinds`); `ShellCallbacks.client`; primitive 164;
  the counter `clientCalls`; the view primitive makes the next poll check
  the budget after a view call past the deadline; `ShellPlatform` gains
  `textDrawn` and `typeKey` (the typing measurement); `ShellRuntime` owns a
  `ClientHost`, adds its own transport as the target `local`, and reports
  each view call's time (`onViewDone`); `ShellResources` names `dev.img`
  and `dev2000.img`, which the macOS build bundles (`build-images.sh <dir>
  mac`); `UIEventLoop`'s actions by kind (`on:do:`), timers (`after:do:`),
  generations and the hand-over; `View>>autoresize:`, `contextMenu:`,
  `Window>>frame`, `toolbar:`; the macOS host's window position (`get x`,
  `get y`), its text view a `KajoTextView`, the new kinds in
  `DevViews.swift`; **the macOS display link asks for 120 Hz only** (it
  asked for 60 to 120: 9a's scenarios moved a view every frame and got
  120; the developer UI moves nothing and got 60 for stretches of the
  first typing run).
- **9b**: three requests (`class.hierarchy`, `package.list`,
  `package.selectors`: 31 now); replies and events written in pieces
  (primitive 161 takes an Array); a result that cannot be written is an
  error reply; the transport refuses a request too long for the image;
  `ProtocolServer` reflects without its token; the fuzz target also checks
  every line as the client's transport would.
- **8b and 8e**: `LargeArray`, `Array class >> large:`, the growable
  collections past one object, `sort:` a merge sort, `Json writePieces:`
  and `Json read:` of pieces (`JsonText`, `JsonPieceStream`), `Smalltalk
  writePackages:`; `kajo build-image --with`.

## Deviations from the brief

- **The tools always speak the protocol**, also to their own image (the
  brief allowed using `DevSession`, `Debugger` and `DebugStop` directly
  there): one path to every target, and the local target exercises the one
  the phone will use.
- **The client primitive never takes the token from the image**: the host
  opens the session with the token it holds; a token typed into the target
  picker passes through the image once.
- **Files are written by the client transport** only when the connection
  names a project directory (`mode=dev project=`, `just tools`); the
  scripted session writes none.
- **The data source is push, with on demand built and measured**, through
  events rather than a toolkit callback into Smalltalk (section 3): the hop
  rule forbids the callback, and an event does its job.
- **iOS gets the text view's second round only**; the outline, table,
  split, scroll, toolbar and menu are AppKit's (the brief: the iOS text
  view built, exercised only by `just apps`).
- **Kernel changes beyond the brief**: `LargeArray`, the merge sort, JSON
  in pieces (section 5): without them a 2000-class image could not be
  built, nor its browser populated.
- **The 2000-class image is 2009 classes** (1806 generated, 11 methods
  each, beside the development image's 203) and its selectors 19 866 (the
  generated package's), not 20 000.
- **The typing latency ends at the text view's draw**, not at the frame
  the window server composited (not observable from the app).
- **The session's error is a workspace doit's** (a request Process stops);
  the error in a tool's own action (the hand-over) is the test's, not the
  measurement's.

## Tests

Swift: `KajoVMTests` as at the start; `KajoCompilerTests` gains
`ToolsTests` (6: the development image builds without warnings and the
tools' SUnit tests pass, both packages written back byte for byte, the
client transport trusts nothing the socket sends, a request too long for
the image refused and a long reply joined, the tools develop the image
they run in, an error in a tool stops only its Process and the tools go
on). Smalltalk: the kernel's tests gain `ViewWrapperTest` (5) and
`LargeArrayTest` (3); `tools/` has 25 (`DevClientTest` 8,
`BrowserModelTest` 7, `DebuggerModelTest` 3, `InspectorModelTest` 2,
`TestRunnerModelTest` 1, `SourceColorerTest` 2, `ToolWindowTest` 2), run
by `ToolsTests` class by class. 312 `KajoVMTests` (as at the start) and 76 `KajoCompilerTests` (70 at the start; Swift Testing's count), whose kernel-image suite runs the kernel's 200 SUnit tests (192 at the start). Waits are bounded (60 s per condition, for a hang only); the
assertions are on what happened.

**`ViewWrapperTest` on every host (2026-11-06, after the first device
run).** As built, the test assumed the headless host: it made every 9c
kind, read back what it had given a view (a text view's styles and keys,
an outline's children and tree, a table's rows and page) and asserted that
a timer is refused. Only the headless wrapper keeps those properties; on
AppKit and UIKit the native view holds them and the protocol has no get
for them, by design (nothing the toolkit holds is mirrored). The iOS text
view has `setStyles` like the Mac's, so `styles` was not missing on UIKit;
no host could answer `get styles`. UIKit has no outline, table, toolbar or
menu, and a host does post timers. On c2de63f the iPhone failed 4 of 202
and the Mac shell's tests mode 3. The test now asks the host: `View class
>> supports: aKind` (true headless; with a shell the view primitive is
asked to make one, the view released at once, and its clean error answers
false), and where a kind is unsupported the test asserts that making one
raises an `Error` and skips the rest of that case; the read-backs run only
where the wrapper keeps its properties itself (`readsBack:`, the
wrapper's `isHeadless`), and after styling the text view the selection is
asserted unchanged on every host; the timer is nil without a host and a
positive token with one (`ClientTransport hasHost`), cancelled at once. A
`tearDown` leaves the main thread as `ViewTest`'s does. 202 of 202 pass
headless (`kajo test`), in the Mac shell's `mode=tests` (AppKit, every
case's full assertions bar the read-backs) and on the iPhone 13 Pro
(`scripts/device.sh tests`; the outline, table, toolbar and menu cases
assert the refusal).

## Broken variants run by hand

Each on the final code with one rule broken, then put back; the outputs
are kept with the gates' (`m9c/broken/`).

| rule | broken variant | test | result |
|---|---|---|---|
| an error in a tool hands the event loop over | `dispatch:` passes the error without starting a new loop | `ToolsTests>>anErrorInAToolStopsOnlyItsProcessAndTheToolsGoOn` | fails: "debuggerReady never held ... loop errors 1": the loop's Process stopped with the error and nothing dispatched the `process.stopped` line; no hand-over, the same loop Process |
| the client transport checks every line | `ClientHost` hands the image the bytes it read | `ToolsTests>>theClientTransportTrustsNothingTheSocketSends` | fails: the three malformed lines arrive as they were, not as `client.error` |
| replies are written in pieces | `DevProtocol reply:result:` writes the result with `Json write:` | `ToolsTests>>aRequestTooLongForTheImageIsRefusedNotDropped` | fails: "no reply to package.selectors within 60.0 s": the writer's ByteArray could not grow past one block and the request got no reply at all (fixed: such a result is now an error reply) |
| the growable collections pass one object | `OrderedCollection` and `HashedCollection` allocate with `Array new:` | `LargeArrayTest`, and building the 2000-class image | fails: "cannot make an instance of Array with 4096 slots" (two of three tests); the build dies in `recordDefinitions:` with a stack overflow |

## Unsafe surface

`Sources/KajoVM` lines with `unsafe` (comments excluded): 4757, against
4753 at the start (4f83594): `Shell/ShellPrimitives.swift` 27 against 23
(primitive 164's blocking region, the countdown after a view call).
`KajoDev` 20 against 16: `ClientHost.swift` 4 (the socket's option,
connect, write and read). `KajoShellCore` 16 as at the start
(`TextOffsets` and `DevModes` have none). The apps' Swift is not built
with strict memory safety. Counted on the final commit's clean build (0
warnings).

## Hot-path check

`just arc-check` on the final code: 135 functions, zero `swift_retain`/`swift_release`; `interpret` 1056 instructions (as at the start), one indirect branch and one jump table. Nothing of this module is on
the checked dispatch, send, return or allocation paths: primitive 164 is
reached through `primitive`'s switch beside 150 to 161; the countdown set
after a view call is in the view primitive (out of line); the kernel's
collections are Smalltalk.

## Not done

- The phone's transport (9d).
- The outline, table, split, scroll, toolbar and menu on iOS.
- Method versions and a changes log; refactorings; a complete keymap (the
  brief's "not in this module"); buttons with images; layout beyond frames
  and autoresizing.
- A large-object space in the VM (section 5's cause); requests longer than
  one heap block are refused, not carried in pieces.
- Why typing on an idle machine missed up to 189 frames of 1258 while the
  VM's turns stayed short.
- The target picker's model has no SUnit test of its own (it lists the
  shell's targets through the primitive); `mode=dev` and `just tools` were
  run by hand (the window opens, the session connects, nothing on the
  Transcript), not in a gate.
- Retrying a request on a connection that dropped (9b's idempotent
  requests): the client fails what was pending and says so; 9d's link will
  want reconnect and retry.

## Open questions for the owner

1. **Large objects.** No object can pass one heap block (32 KiB), so 9c
   added `LargeArray` to the kernel's growable collections and pieces to
   the protocol's lines. Keep that kernel-level answer, or should the VM
   get a large-object space (ADR 0003, 0007 territory: such objects would
   not move)? Provisional: the kernel's, until an app needs a large
   ByteArray or String.
2. **The data-source form.** The tools push (every item in the toolkit's
   data source); on demand is built and measured (6 to 7 times faster for a 20 000-row table). Make on demand the default above some size, or keep
   push and choose per view? Provisional: push, on demand for long lists.
3. **A tool's error.** While the protocol serves, an error in a tool stops
   that event's Process for the debugger and a new event loop takes over.
   Is that right for the developer image, or should a tool's error be
   reported and the event dropped, as 9a did? Provisional: stop, the
   developer image's point is the debugger.
4. **The local target.** The tools and the code they change share one
   image; a broken tool breaks the tools. Develop apps against a second
   image (their own target) and keep the local target for the tools
   themselves? Provisional: yes, the target picker connects to any.
5. **Tokens in the image.** The host opens every session with the token it
   holds; a token typed into the target picker passes through the image
   once and is not kept. Refuse typed tokens (only `~/.kajo/targets` and
   the shell's own)? Provisional: allow.

### The owner's answers (2026-11-05)

1. **Large objects: a large-object space in the VM**, as a module of its
   own after 9d (ADR 0003 and 0007 territory: such objects do not move).
   `LargeArray` and the pieced lines stay until it exists; 9d found no
   reply over the link that needed more (the largest was 57 KB).
2. **Data source: push by default, on demand for long lists.**
3. **A tool's error stops its Process for the debugger.**
4. **Apps are developed against a second target image**; the local target
   is for the tools themselves, and the project directory is the changes
   file (the owner asked how the other remote Smalltalks did it: GemStone's
   GemTools and Jade, TelePharo and Newspeak's mirrors keep the tools in a
   client image apart from the target; the one-image Smalltalks rely on the
   changes file and the emergency evaluator).
5. **No token in the image, typed ones included**: the target picker asks
   the host, which takes the token in a secure field of its own; built in
   9d, which removed the typed path (primitive 164's `connect` lost its
   token argument).

## What 9d needs

- **A transport in `ClientHost`**: TCP to the phone (9b's answer: Bonjour
  and the pairing token), behind the same ops (`connect` by a target name
  or address, `send`, `close`, `targets`), the phones Bonjour finds listed
  by `targets`; the token kept in the host (the pairing is the host's, the
  image never sees it).
- **The target side on iOS**: the iOS shell serving the protocol
  (`ShellRuntime.serveProtocol` over TCP), and the kernel's replies and
  events in pieces already (a reply's length is not bounded by one block).
- **A link that drops**: the client fails pending requests at `lost`;
  9d needs reconnect and a retry of the idempotent requests (9b made them
  so), and the target picker showing the state (it does: `connection.lost`
  and `connection.open`).
- **Latency**: every tool already waits by callback with a 30 s timeout;
  the local round trips here (0.4 to 10 ms for the small requests, 0.33 s
  for the 2000-class hierarchy) are the baseline to compare the phone's
  with. The 2000-class hierarchy is 190 KB: over a slow link the class
  tree may want the on-demand form or a request per package.
- **Files**: the phone's replies carry `files`; the Mac's client transport
  writes them into the project directory given at connect, unchanged.
- **Nothing of the developer UI runs on the phone**: the iOS shell needs
  only 9a's wrappers for the app; the second round's AppKit kinds stay on
  the Mac.

**As 9d used it** (`docs/modules/phone-transport.md`): the client
transport's ops stayed the five of primitive 164; `connect` takes a target
name or an address (a socket path, `tcp://host:port`, `bonjour:<name>`),
resolved and connected on the connection's thread through one stream
opener the Swift client shares, and `targets` lists the `_kajo-dev._tcp`
services a Bonjour browser sees with the rest, a change of that list being
a new event kind (`targets`, 17) the target picker refreshes on. The token
stays in the host, and since the owner's decision of 2026-11-05 (this
module's question 5) a token is never typed into the image either: the
picker's Pair button has the host take it in a secure field of its own
(`ClientTransport pair:`, the host's `pairing` op), and `connect` lost its
token argument.
`DevClient` reconnects after a dropped link (timer events, 1, 2, 4 s up to
a minute, a new session as the same client and package) and sends again
every pending request but `evaluate`, `process.evaluate`, `process.step`
and `test.run`; a refused session and `close` end it for good; the target
picker shows `reconnecting`; the debuggers refresh from `process.list`
when the session opens again. `files` are written into the project given
at connect as before (the remote session's changes landed in the Mac's
project directory). The round trips over TCP are compared with this
module's local ones there. Nothing of the developer UI runs on the phone.

## Gates

The code is 2650aea's; this doc (and ADR 0010's note) were edited in the
working tree during the run and committed after it (`gates.log` counts 2
files changed, both under `docs/`). Every gate ran on 2650aea, Mac mini
(M2 Pro), swift.org 6.4.2 first on PATH, Xcode 27.2 for the apps,
2026-11-05 05:56 to 07:57, every output in a file, each step logged with
the commit it ran on. "Load" is twelve `yes` busy loops.

Three earlier attempts found three things, each fixed and every gate run
again: the scripted session's steps overlapped (a step that recorded a part
started the next one; the tables showed it) and the display link dropped
to 60 Hz while typing on an idle machine; `swift test` under load failed
once where "define the method" found its browser showing the class
definition, not the template (a definition reply still on its way replaced
it: the browser's pane now shows only the reply to its last request);
`just test-release` failed once on `tenThousandParkedProcesses` (a module 3
race in the test: a termination is counted after the scheduler lock is let
go; the Process tests now wait for the counter), and ThreadSanitizer under
load once read the compiled method's file before the compile's reply had
written it (the test now waits for the reply).

| gate | result |
|---|---|
| `swift test` | 312 + 76 passed, 230 + 79 s |
| under load (12 busy loops) | 312 + 76 passed, 276 + 95 s |
| ThreadSanitizer | 312 + 76 passed, 0 reports, 446 + 1974 s |
| ThreadSanitizer under load | 312 + 76 passed, 0 reports, 606 + 2408 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release in 135 functions, `interpret` 1056 instructions, one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 312 + 76 passed |
| `just model-check` | 28 + 5 + 15 passed |
| `just soak` | passed: 1000 seeds under every configuration, no failing seed; the snapshot modes saving 762 to 979 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.34 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 3.61 million runs, no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 0.91 million runs, no crash |
| `just fuzz protocol 600` | libFuzzer build ok, 1.78 million runs (each line also through the client's check and its pieces), no crash |
| `just mac-shell`: the scripted session and the typing measurement | 12 launches (three each of the session with no load and with the storm, typing with the storm and with none), every result line written, no failure; tables under Measurements |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| clean build | exit 0, 0 errors, 0 warnings |

(312 is `KajoVMTests`, 76 `KajoCompilerTests`.) The four fuzzers ran at
the same time, one core each. The bench A/B (Measurements) ran on 350d689
before the run; the VM has not changed since.

## Commands

```zsh
just dev-image                                    # kernel/ and tools/ into dev.img
just tools                                        # the developer UI on dev.img, changes written to tools/
scripts/canonical-tonel.sh [--check]              # kernel/ and tools/ in the form the image writes
swift run kajo build-image -o x.img --with tools --with <dir>
python3 scripts/gen-classes.py <dir> 1806 11      # the 2000-class package
just mac-shell run out.txt mode=devsession classes=2000 load=none
just mac-shell run out.txt mode=devsession classes=0 typing=200 load=storm
python3 scripts/devsession-report.py out.txt
swift test --filter ToolsTests
swift run kajo test dev.img --filter 'BrowserModelTest>>'
```
