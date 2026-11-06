# ADR 0011: One development protocol, requests as methods in the image

Date: 2026-11-04
Status: proposed (module 9b, `docs/modules/development-protocol.md`)

## Context

AGENTS.md's first use case is developing an iOS app live from a Mac, with
a developer UI in Smalltalk and an AI agent beside it. Three kinds of
client therefore reach one running image (the target: the iOS shell, the
macOS shell, a headless `kajo run`): the developer UI of module 9c, an
agent through MCP, and a person or a script at a terminal. They need the
same things (browse, change, evaluate, inspect, debug, run tests), the
image must stay the authority on what a change means (8d's make primitive
and 8e's class primitives are the trust boundary), and the phone's link
(module 9d) may be slow and lossy. The owner's answers of 2026-11-04 fixed
the split: Swift for the compiler and the bindings, Smalltalk for every
developer tool; MCP and a CLI both; agent changes marked; stopped
Processes wait with no timeout in development and never stop in release.

## Decision

- **One protocol for every client.** JSON objects, one per line, both
  ways over one connection: requests `{"v":1,"id":...,"kind":"...","args":{...}}`,
  replies `{"v":1,"kind":"reply","id":...,"ok":true,"result":...}` or
  `"ok":false,"error":"..."`, and events (8b's stream unchanged:
  `transcript`, `test.*`, `run.*`, `gc`; new: `process.stopped`,
  `process.resumed`). An error is a reply, never a dropped connection.
- **A request is a method.** Every request is an instance method of
  `DevSession` marked `<devProtocol>` (the pragma 8b declared); its kind is
  its selector's first keyword split before the first capital
  (`processRetrySend:` is `process.retrySend`), its arguments are its own
  argument names, its comment is the description. `protocol.describe`
  lists them; the MCP server makes them its tools. Adding a request is
  adding a method, from any package. A method also marked `<debuggable>`
  lets an unhandled error stop its Process for the debugger instead of
  replying with it (`evaluate`).
- **The image owns the meaning, the host owns the socket.** The host's
  transport (`Sources/KajoDev`) parses and checks every line (bounded JSON,
  the request's shape, the names) and hands the image only the canonical
  form of a checked request (primitives 159 and 160, the protocol inbox,
  one Semaphore signal per request); the image answers through the event
  callback 9a's host surface has (primitive 161), the transport routing a
  reply to its connection by its `conn`. The parser is fuzzed
  (`just fuzz protocol`).
- **One protocol Process, one Process per request.** The protocol Process
  runs at the highest priority and only reads and dispatches; each request
  runs in a Process of its own, so a long request (a test run, which
  streams its events) or a stopped one never blocks the next.
- **No session without the token.** The target makes a short random token
  (20 letters and digits) when it opens the transport and shows it (`kajo
  run` prints it, the Mac shell's status line); the first request of a
  connection is `session.open` with the token and the client's name, or
  the connection is refused and closed. The target never writes the token
  to a file. The transport is a Unix-domain socket the user alone may open
  (module 9d adds TCP with Bonjour and the same token for the phone).
- **Development images only.** In a release image (8d's flag) the
  transport does not open and the inbox primitives fail; there is no
  protocol Process and no stop on error.
- **An unhandled error stops its Process** while the protocol serves (the
  default action of UnhandledError): the Process waits for the debugger
  with its stack intact, no timeout, and clients act on it (frames,
  evaluate in a frame, proceed, restart a frame, retry a send, step,
  terminate). The stopped Process runs the commands itself, on its own
  stack, where its Contexts are live. Without the protocol (`kajo test`,
  plain `kajo run`) and always in a release image the error is reported
  and the Process ends, as before.
- **Changes are marked.** A session names its client (`developer`,
  `agent:<name>`) and its package; every method it compiles records that
  author and package, and Tonel writes the author in the method's metadata
  (`{ #category : ..., #author : ... }`), so the browser and `git diff`
  show what an agent changed. Sources go to the project directory on the
  client's side after every change the target accepts: the reply carries
  the class's file of the session's package, or the package's extension
  file of a class another package owns.
- **What an agent may never do is enforced in the target**: nothing in a
  release image, no file outside the project directory (the file
  primitives' one directory, and the client's writer takes file names
  only), no session without the token. Otherwise an agent has the
  developer's rights.

## Consequences

- The developer UI (9c) is a client of the same requests, from Smalltalk;
  it needs no second channel. The CLI and MCP are thin.
- The kernel grows a JSON reader and writer, DevProtocol, DevSession,
  Debugger and DebugStop; the VM grows primitives 155 to 163 and two VM
  selectors (`stopForDebugger`, `stopForDebuggerAfterSend`) beside
  `terminateUnwinding` (image version 4).
- A request that runs user code (`evaluate`) can stop; its reply then says
  so and names the Process, and the result of the evaluation, if it is
  ever resumed, is not sent (the reply was).
- Unhandled errors in a development target no longer end Processes: a
  program that relied on that (an error ending a worker Process) leaves
  stopped Processes behind, visible in `process.list` and in the Mac
  shell's status line.

## Open

- Whether objects of the reply should carry more than a printString and a
  handle (9c's inspector will say).
- Whether a stopped request's eventual result should be sent as an event.
- TCP, Bonjour and the phone's pairing (9d).

## Built (9d)

Module 9d (`docs/modules/phone-transport.md`) put TCP and Bonjour beside
the Unix socket, as this ADR's Open item said. One accept loop serves
both (`ProtocolServer(tcpPort:)`), with the same bounded reader, the same
first-line token rule and the same 64 MiB drop; on a network where every
host may try the token, three failed `session.open` close a connection and
ten failures within a minute make the listener refuse every connection for
a minute. The iOS shell serves when launched with `protocol=tcp[:port]`
(`mode=serve`), only from a development image, and shows its token on a
pairing screen with its Bonjour name (`_kajo-dev._tcp`, the TXT record
without the token) and addresses; the token is kept per install in the
app's Application Support with mode 0600 and a new one ends every session.
No token passes through the image, not even a typed one (the owner,
2026-11-05): a phone is paired by typing the token its screen shows into
the host's own secure field. The Mac's `ClientHost` and the Swift client reach a target by a name, a
socket path, `tcp://host:port` or `bonjour:<name>` through one stream
opener (`openStream`), browse the phones (`NWBrowser`, a `targets` event
when the list changes) and keep every token in the host. A dropped link
is the client's to repair: `DevClient` reconnects with a growing wait and
sends again every pending request but `evaluate`, `process.evaluate`,
`process.step` and `test.run`, which may have run once already; stopped
Processes live in the target and the debuggers refresh from
`process.list`. The link is plain TCP: encryption is the owner's question
(the module's open questions suggest the pairing token as a TLS
pre-shared key). The first remote session was measured Mac to Mac (the
macOS shell in the phone's serve mode, and `kajo run --protocol tcp`):
the iPhone build could not be signed on the mini during the module
(codesign waited on a keychain prompt), so the phone's rows are not done.

## Built (11a)

Module 11a (`docs/modules/app-project.md`, ADR 0014) made serving a
property of a generated app's Debug build: it serves over TCP from launch
with no argument, advertised as "<app> on <device>", with 9d's
per-install token, and its pairing screen is a shake away on iOS and in
the app menu on the Mac. A Release build links none of the transport
(checked on the binary by `just new-check`) on top of its image refusing
to serve. The shells keep serving by launch argument.
