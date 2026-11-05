# Module 9d: the phone transport

Status: built, 2026-11-05, from the brief of the same day (module 9c's
"What 9d needs" and the owner's answer of 2026-11-04 to the 9b draft: "TCP
with Bonjour and a pairing token, development images only"). Builds on 9b's
protocol and Unix-socket transport (`docs/modules/development-protocol.md`,
ADR 0011) and 9c's client in the image (`DevClient` over primitive 164 and
`KajoDev.ClientHost`, `docs/modules/developer-ui.md`). Module 9 is four
builds: 9a (the shells), 9b (the protocol and the debugger), 9c (the
developer UI) and **9d (this)**, the transport that puts a phone at the
other end of the same requests.

**The phone's part is not done.** Every piece the iPhone runs is built
and compiles for iOS (`just apps`), but the signed build for the attached
iPhone 13 Pro could not be made on the Mac mini during the module: twice,
`codesign` sat at 0 percent CPU for minutes inside `scripts/device.sh
build`, waiting on a keychain prompt on the Mac's screen (the 9a and 9c
device runs signed with the same identity). Answering it would change the
keychain's access rules, which the module may not do, so the phone could
not run the new code. As the brief says for an unreachable phone, the
transport was measured Mac to Mac instead: the macOS shell in the phone's
serve mode (the same `KajoShellCore` code the iOS shell runs: the
scenario, the TCP listener, the Bonjour advertisement, the token kept in a
file) and `kajo run --protocol tcp` as a second target, reached over
loopback, the Mac's LAN address and its Bonjour name. Section 3's phone
rows, its thermal states and the phone's frames are in "Not done" with the
commands that make them once the build signs (`scripts/remote-session.sh
device`).

**2026-11-06, the devices.** The iPhone build signs now (the owner allowed
codesign on the key): the iOS shell built, signed and installed on the
iPhone 13 Pro in about a minute, served over TCP on it and kept every
frame while serving (Measurements, "On the devices"). Section 3's rows
with a client still did not run, for two reasons outside the code: from
the agent's session on the Mac every host of the LAN but the router
answers "No route to host" (the phone, the iPad, another Mac; the same
with the agent's sandbox off), which is macOS's local network privacy
refusing the session's processes, so the macOS shell started from it
cannot reach the phone either; and the phone's `_kajo-dev._tcp`
advertisement never appeared on the network, which points at iOS's local
network permission for the shell, not yet given on the phone. The iPad Pro
attached the same day could not be built for (its signing needs Xcode's
account, below).

New: `Sources/KajoDev/Transport.swift` (the address forms, one stream
opener for every transport, the TXT record, Bonjour advertising,
resolving and browsing, the machine's addresses),
`Sources/KajoShellCore/Serving.swift` (a shell serving over TCP, the
pairing token kept per install, the pairing screen's contents), the
pairing screen in `apps/KajoShell-iOS/Sources/IOSShell.swift`,
`apps/Shared/smalltalk/DevSessionTarget.class.st` (what the session does
to a target other than its own image), `tools/TargetPickerModelTest`,
`scripts/remote-session.sh` and `scripts/remote-report.py` (the remote
session and its tables), `Tests/KajoCompilerTests/PhoneTransportTests.swift`
(6 tests) and two fuzz seeds. Changed: `ProtocolServer` (TCP, the failure
limits, a replaceable token, counters), `ClientHost` (addresses, Bonjour,
the `targets` event, pairing in a secure field of the host's, a dropped link), the Swift client
and the CLI (any address or target name), `DevTarget` and `kajo run
--protocol tcp[:port] [--name]`, `DevClient` (reconnect and retry),
`DevTools`, `TargetPickerModel`, `DevSessionBench` (the remote session,
two new steps), `scripts/device.sh` (`serve`, `token`), the iOS shell's
`Info.plist`.

## What it hides

That the target is on another machine. The tools of a development image
on the Mac connect to a target named in the target picker, and whether it
is the image's own socket, another process on the Mac, or the iOS shell
on the phone, the requests, the replies, the events, the debugger and the
files written to the project are the same: the image never sees an
address's form, a port or a token (`ClientHost` owns them, 9c's rule).
Also hidden: how a target is found (a name in `~/.kajo/targets`, a Bonjour
service the network shows), that the link may drop (the client
reconnects and sends again what may be sent again), and that a network
lets anyone try the token (the listener's limits).

## 1. The target side

### One accept loop, two transports

`ProtocolServer(tcpPort:loopbackOnly:token:post:)` listens on TCP beside
9b's `ProtocolServer(path:)`: one IPv6 socket that takes IPv4 too on every
interface (port 0: the system picks; `port` says which), or IPv4's
127.0.0.1 alone for the tests. Everything after the listening socket is
9b's: one accept thread, a reading thread per connection with the bounded
reader (1 MiB per line), the first-line token rule, a serial writing queue
per connection and the 64 MiB drop of a client that stops reading. A TCP
connection gets `TCP_NODELAY` (the lines are small and wanted at once) and
keepalive probes after 10 s of silence (5 s apart, three), so a phone that
left the network without a word is noticed in about 25 s. `path` is where
a client on the same machine reaches the server (`tcp://127.0.0.1:<port>`
for TCP), which the shell's own tools use as their local target.

**The writer never blocks the protocol Process.** A reply or event leaves
the image through primitive 161 on the VM thread that emitted it;
`deliver` only routes it and queues it on the connection's writing queue
(a `DispatchQueue` per connection owns the socket's writes, as in 9b's
server). Measured on the serving shell (Measurements): `deliver` took
4.6 to 6.6 µs on average (at most 86.5 µs) on the VM thread, and at
most 55.5 KB waited in a writing queue.

### Who may connect over the network

The token rule is 9b's (`session.open` with the token first, compared in
constant time), with limits for a network where every host may try:

- A `session.open` with a wrong token is a failed attempt: the error reply,
  and the connection stays open for another try; the third closes it. A
  first request that is not `session.open` still closes the connection at
  once (9b). This holds on both transports.
- Both count as **failed pairings** for the listener: ten within a minute
  and it refuses every connection for a minute (accepted and closed at
  once, counted as `refusedConnections`), calls `onRefusing(true,
  failures)` and, when the minute is over, `onRefusing(false, 0)`. The
  phone's pairing screen says so. The clock is the server's own (`clock`),
  so a test sees a minute pass without waiting one.
- `replaceToken` makes a new token and ends every connection: a session
  opened with the old token is over.

The line is plain TCP on the owner's network: whoever can see the traffic
can read the token at a session's start and everything after it. TLS is
the owner's question ("Open questions").

### The pairing token

`PairingTokenStore` keeps the token per install: 20 letters and digits
(9b's `makeToken`), in the app's Application Support directory as
`kajo-pairing-token`, created with mode 0600 (`O_CREAT | O_EXCL |
O_NOFOLLOW` on a temporary name, then renamed over the old one), read back
at every launch, made again by the pairing screen's **New token** button,
which also replaces the server's token (every session ends). The token is
never logged, never in a result line (the serving shell's console line is
`serving=tcp port=<n> addresses=<...>`), never in the TXT record. On the
Mac the token stays in memory and the shell's status line shows it (9b's
way), unless `tokendir=` names a directory for the store: the Mac-to-Mac
measurement reads it from there as `scripts/device.sh token` copies the
phone's from its app container.

### Bonjour

The serving shell registers `_kajo-dev._tcp` with dns_sd's
`DNSServiceRegister` (`BonjourAdvertiser`, replies on a queue of its own),
under the device's name by default (`bonjour=<name>` names it; the system
renames on a conflict and the registered name comes back to the pairing
screen). Network.framework's `NWListener` would have advertised too, but it
owns its listening socket, and the brief's one accept loop is a BSD
socket's. The TXT record is `image=shell.img`, `protocol=1`,
`kernel=<KajoVM.version>`; never the token. `NSBonjourServices` lists the
type in the iOS shell's `Info.plist` and project spec;
`NSLocalNetworkUsageDescription` is there too, although the shell does not
browse: iOS's local network privacy is documented to cover advertising and
accepting connections from the local network as well as browsing, and
without the string iOS cannot ask. Whether it asks on the phone is not
known (the phone did not run this build).

### The serve mode and the pairing screen

`mode=serve` (or `protocol=tcp[:port]` in `mode=scenario`) runs a 9a
scenario (`scenario=idle` by default) while serving over TCP:
`ShellRuntime.serveTCP` opens the listener, starts `DevProtocol` (a
release image answers false and nothing opens, on any transport),
advertises, and shows the pairing screen; the scenario's result line adds
what the server did in the window (`served_sessions`, `served_requests`,
`served_bytes`, failed and refused pairings, `deliver_mean_us`,
`deliver_max_us`, `writer_max_pending_kb`). A development image serves TCP
only when asked: no launch argument, no listener. The iOS pairing screen
is a panel above every Smalltalk window: "Kajo serves: <Bonjour name>",
the token in 28-point monospaced bold, each address with the port, what
the listener does (serving, or refusing for a minute after N failed
pairings), and the New token button. The macOS shell shows the same in
its status line.

## 2. The Mac side

### Addresses and names

`TargetAddress` reads the three address forms a person types and a
targets file holds: a Unix socket's path (any text with a `/` that fits
`sun_path`), `tcp://host:port` (a DNS name or an IPv4 address, or an IPv6
one in brackets with an optional zone), `bonjour:<name>` (a DNS-SD
instance name, 1 to 63 bytes without control characters). Everything else
is refused, and what is accepted writes back as itself with no tab or line
break (the image gets targets as tab-separated lines). `openStream`
connects to any of them on the calling thread: a Unix socket as before; a
host through the resolver, each address it gives tried in turn with a
non-blocking connect and a deadline (so `localhost` tries ::1, then
127.0.0.1); a Bonjour name resolved first (dns_sd's `DNSServiceResolve`
with a deadline; its TXT record must say protocol 1; a service found on
the loopback interface is this machine and is reached at `localhost`).
`ClientHost`'s connections and the Swift client (`ProtocolClient`, the
CLI's and the MCP server's) both open through it: one transport
implementation behind both.

### `ClientHost`

- **`connect`** takes a target name or an address. A name is looked up in
  the known targets (the shell's own, `~/.kajo/targets`, those added) and
  then among the Bonjour services; an address stands for itself. The
  token is the one the host holds for that address (primitive 164's
  `connect` has no token argument any more: target, client, package,
  project). Resolution, connect and `session.open` run on
  the connection's own thread as in 9c; the image waits by callback.
- **Pairing (`pairing`, the owner's decision of 2026-11-05: no token
  passes through the image, not even a typed one).** The target picker's
  Pair button sends `ClientTransport pair: <target>`; the host asks for
  the token in a secure field of its own (the macOS shell's
  `NSSecureTextField` in an alert, after the turn that asked; the iOS
  shell's secure `UIAlertController` field; a test's fake), keeps what
  was typed in memory for the target's address (letters and digits, at
  most 128), and posts a `targets` event; the op answers only whether a
  token was held already. The picker shows a target the host holds no
  token for as "no token". This is how a phone is paired: read the token
  off its screen, type it into the host's field. A reconnect after a
  dropped link opens its session with the same token.
- **`targets`** lists the known targets and then every `_kajo-dev._tcp`
  service the browser sees that is not already known by its address
  (`name TAB bonjour:<name> TAB 1/0`). `startBrowsing` runs
  Network.framework's `NWBrowser` (with the TXT record; each pair checked,
  at most 16 of at most 128 bytes) and posts a **`targets` event** (event
  kind 17, `UIEvent kinds` gains `#targets`) whenever the set of names
  changes; `DevClient onTargetsChanged:` gives it to the target pickers.
- **The targets file** keeps 9c's form, `name address [token]`, with any
  address form; a line with a tab is split on tabs, so a Bonjour name
  with blanks fits (`phone<TAB>bonjour:Joni’s iPhone<TAB><token>`). A
  name is 1 to 64 bytes without control characters, a token letters and
  digits; a line that is not exactly that is skipped.
- **`dropConnections`** ends every connection's socket as a dead link
  would (`shutdown`, no `close` from the client): the reader sees the end
  and the image gets a `lost` event, and the `DevClient` reconnects. The
  measurement's dropped link and the tests' use it.

### The CLI and MCP

`--target` takes a socket path, `tcp://host:port`, `bonjour:<name>`, a
name in `~/.kajo/targets` (or the file `KAJO_TARGETS` names), or a bare
Bonjour name; the token is `--token`, `KAJO_TOKEN`, or the targets
file's. So `kajo eval --target phone '3 + 4'`, `kajo debug --target
phone list`, `kajo test --target phone` and `kajo mcp --target phone`
reach a phone the file names. `kajo run <image> --protocol tcp[:port]
[--name <Bonjour name>]` serves on TCP, advertised, and prints the port
and the machine's addresses with the token (9b's way for `kajo run`).

## 3. A dropped link: reconnect and retry

The state of a `DevClient` is `#connecting`, `#open`, `#reconnecting` or
`#lost` (for good). When a connection ends:

- Closed by the client (`close`), never opened, or refused (a wrong
  token): every pending request fails, `connection.lost`, the end. A
  refused session is closed by the client at once (the server keeps a
  connection open for another attempt now) and never reconnected: a new
  token on the phone ends sessions for good.
- Otherwise it is a **dropped link**: the pending requests the client may
  not send again fail with "... is not sent again", the rest stay
  pending; `connection.lost`, then `connection.reconnecting` with the
  wait; a timer event (`UIEventLoop after:do:`) after 1 s calls
  `reconnect`: a new connection to the same name or address (the host
  resolves it again, and opens the session with the token it holds), a
  new session as the same client in the same package, the same project
  directory. If that connection ends too, the next wait doubles (1, 2,
  4, 8 s, up to a minute), until `close`.
- When the new session's reply arrives: `#open`, the wait back to 1 s,
  every pending request sent again on the new connection with its id
  (requests made while reconnecting waited unsent and go now), the outage
  recorded (`outages`: microseconds from the loss to the new session, and
  how many were sent again), `connection.open`.

**What is not sent again** (`DevClient class >> notRetried`): `evaluate`,
`process.evaluate`, `process.step` and `test.run`. Each may have run in
the target before the link dropped, and running it twice is not running
it once (a doit's side effects, a second step, a second test run's
events). Every other request is idempotent (9b): a read, a compile of the
same source, a definition of the same class, a command on a stopped
Process (`process.proceed`, `restart`, `retrySend`, `terminate`,
`suspend`) answers an error once the Process is no longer stopped, so a
retried command acts at most once; its reply may then be that error
although the first one acted. A retried request's round trip counts from
its first send, the outage included, and is kept apart (`'kind
(retried)'` in `latencies`).

**The debugger survives the link.** Stopped Processes are the target's;
the session's end releases its handles but not them (9b). On a
reconnect's `connection.open`, `DevTools reconnected:` asks `process.list`
and each debugger of that client fetches its frames again, or says its
Process went on. **The target picker** shows each target's state
(`reconnecting` among them) and "reconnecting in N s (why)" in its status
line, and lists the host's targets again on a `targets` event.

No new cross-thread protocol: the reconnect is the event loop's (timer and
line events, one Process), and the TCP writer is 9b's writing queue. The
models under `models/` are untouched.

## The remote session

`mode=devsession target=<name|address> targets=<file> project=<dir>
[package=Kernel]` (the macOS shell, `scripts/mac-shell.sh run ...`) runs
9c's scripted session against another target: the client transport reads
the targets file and browses Bonjour, the image does not serve itself,
and `DevSessionBench startRemote:package:project:` opens the tools on the
target (`DevTools openTarget:name:project:`). On a target other than its
own image the session works on `DevSessionTarget` (in
`apps/Shared/smalltalk`, so in the phone's shell image): a `reset` step
first puts `failingStep` back and removes `undefinedStep`, so one serving
launch takes several sessions. Both forms of the session, local and
remote, end with two new steps:

- **`define.retry`**: a doit (`DevSessionTarget new definedLater`) stops
  at `undefinedStep` in the target; the Mac's debugger opens on it,
  "define method" opens a browser with a template, accepting `undefinedStep
  ^ 41` compiles it in the target, the send is retried, and the Process
  goes on (`process.resumed`); the class's file is written into the
  project directory.
- **`drop.stop`, `drop.reconnect`, `drop.terminate`**: a doit stops in the
  target (`stopForDrop`); the bench writes `devsession: drop` and the
  shell drops every client socket in that turn (`dropConnections`); the
  bench sends `class.hierarchy` and `process.list` on the dead link; the
  step ends when the client is open again on a new session, both replies
  have come, the stopped Process is listed as stopped and its debugger has
  fetched its frames again; then the Process is terminated.

`scripts/remote-session.sh <device|mac|kajo> <outdir> <tag> <scenario>
<form> <sessions>` runs a serving target and sessions against it: the
phone through `scripts/device.sh serve` and `token`, the macOS shell in
`mode=serve`, or `kajo run --protocol tcp`; the session names it by its
LAN address, loopback or Bonjour name; the token goes from the target into
a targets file of mode 0600 and from there into the client shell's memory.
`scripts/remote-report.py` makes the tables below.

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS
27.2, its display a Samsung TV at 2560 x 1440 and 120 Hz; swift.org Swift
6.4.2 for `kajo` and the gates, Xcode 27.2 for the apps (Release). **Mac to
Mac** below; what the devices ran is under "On the devices", with these
tables kept for the comparison. Every number below is from the gate
run on a487630, 2026-11-05 12:42 to 12:53 (`m9d/section3/`, `scripts/remote-session.sh`
and `scripts/remote-report.py`), three runs of each row interleaved,
medians with the range in brackets; thermal state fair throughout (the
Mac's; a first full run on 7982a3c two hours earlier, at nominal, gave the
same picture). Targets: the macOS shell in `mode=serve scenario=idle`
(the shell image, 176 classes and 2072 methods, the iOS shell's code
path), reached at 127.0.0.1, at the Mac's LAN address 192.168.1.10 and
by its Bonjour name; `kajo run shell.img --protocol tcp` (release) at the
LAN address; and, for the comparison, 9c's local form (`mode=devsession
classes=0`: the development image's tools on its own Unix socket, 203
classes). The client is the macOS shell's scripted session
(`mode=devsession classes=0 target=...`) in a second process on the same
display.

### Round trips

From `DevClient`'s send to the reply's dispatch in the client's event
loop; per kind: requests per session, then the p50 of the three
sessions' p50 [their range] / the max of their maxima, in ms. With 1 to 14
of a kind per session the p99 is the max. 9c's column is its published
local p50 with 2009 classes (the requests whose size grows with the
image say so).

| request | local (Unix socket, its own image) | TCP 127.0.0.1 | TCP 192.168.1.10 | Bonjour name | kajo run, TCP LAN | 9c local p50 |
|---|--:|--:|--:|--:|--:|--:|
| `class.definition` | 12: 2.5 [1.7–3.0] / 6.5 | 12: 0.8 [0.7–0.8] / 4.6 | 12: 0.8 [0.8–0.9] / 6.8 | 12: 1.5 [0.8–1.7] / 5.7 | 12: 1.7 [1.6–2.6] / 31.8 | 2.8 |
| `class.hierarchy` | 5: 31.6 [31.5–38.6] / 47.0 | 5: 30.1 [25.2–30.2] / 32.6 | 5: 29.0 [26.1–30.8] / 31.6 | 5: 33.2 [32.7–33.6] / 433.4 | 5: 28.8 [27.0–30.0] / 31.5 | 329 (2009 classes) |
| `class.hierarchy (retried)` | 1: 1043.5 [1040.7–1068.0] / 1068.0 | 1: 1041.9 [1033.9–1049.5] / 1049.5 | 1: 1049.8 [1033.4–1050.2] / 1050.2 | 1: 1056.9 [1040.9–1064.8] / 1064.8 | 1: 1036.5 [1034.6–1052.0] / 1052.0 | - |
| `class.selectors` | 14: 2.7 [1.6–2.9] / 31.1 | 14: 1.2 [1.1–1.3] / 30.5 | 14: 1.1 [1.0–1.6] / 57.6 | 14: 1.8 [1.3–2.3] / 48.8 | 14: 1.5 [1.4–2.1] / 55.3 | 4.2 |
| `evaluate` | 3: 7.2 [0.5–34.4] / 38.2 | 3: 1.1 [0.7–4.4] / 8.7 | 3: 4.5 [0.7–4.6] / 8.7 | 3: 0.7 [0.6–0.8] / 24.7 | 3: 4.5 [4.3–5.4] / 8.6 | 2.6 |
| `method.compile` | 3: 2.9 [0.8–3.4] / 27.2 | 4: 3.6 [3.1–3.9] / 6.7 | 4: 3.6 [3.5–5.4] / 6.7 | 4: 5.5 [4.8–5.6] / 16.9 | 4: 4.2 [4.1–5.0] / 39.9 | 0.9 |
| `method.remove` | - | 1: 3.1 [2.6–3.1] / 3.1 | 1: 3.0 [3.0–3.1] / 3.1 | 1: 4.6 [4.0–4.7] / 4.7 | 1: 3.5 [3.2–3.6] / 3.6 | - |
| `method.source` | 10: 0.6 [0.5–1.0] / 9.3 | 7: 0.6 [0.6–0.7] / 17.1 | 7: 0.6 [0.6–0.7] / 14.7 | 7: 0.8 [0.7–0.8] / 7.1 | 7: 0.6 / 16.4 | 0.4 |
| `package.list` | 4: 2.7 [2.1–2.9] / 13.8 | 4: 2.0 [1.8–2.2] / 13.4 | 4: 2.0 [1.0–2.1] / 11.4 | 4: 2.5 [2.5–2.6] / 402.0 | 4: 1.0 [0.9–2.1] / 10.9 | 8.5 |
| `package.selectors` | 2: 11.0 [10.9–11.1] / 19.7 | 2: 72.2 [69.4–80.0] / 80.4 | 2: 78.1 [75.2–78.1] / 82.6 | 2: 72.8 [67.3–83.7] / 91.0 | 2: 72.5 [69.0–81.1] / 83.7 | 657 (19 866) |
| `process.frames` | 6: 35.0 [33.7–60.3] / 84.1 | 6: 41.9 [36.4–42.6] / 81.7 | 6: 42.1 [28.9–51.1] / 88.6 | 6: 42.6 [24.7–42.9] / 91.7 | 6: 29.4 [25.5–50.2] / 75.4 | 17.3 |
| `process.list` | 1: 8.1 [2.3–9.4] / 9.4 | 1: 1.6 [1.2–1.7] / 1.7 | 1: 1.8 [1.0–2.0] / 2.0 | 1: 1.8 [1.3–2.1] / 2.1 | 1: 6.4 [6.2–9.0] / 9.0 | - |
| `process.list (retried)` | 1: 1008.4 [1008.2–1016.5] / 1016.5 | 1: 1007.0 [1005.4–1009.8] / 1009.8 | 1: 1006.5 [1006.4–1008.6] / 1008.6 | 1: 1022.0 [1018.1–1024.1] / 1024.1 | 1: 1012.8 [1012.5–1013.7] / 1013.7 | - |
| `process.restart` | 1: 0.4 [0.3–2.0] / 2.0 | 1: 0.8 [0.6–7.5] / 7.5 | 1: 0.6 [0.5–0.6] / 0.6 | 1: 0.5 [0.5–0.8] / 0.8 | 1: 0.5 [0.5–0.6] / 0.6 | 0.4 |
| `process.retrySend` | 1: 5.2 [2.5–30.5] / 30.5 | 1: 25.3 [25.0–26.2] / 26.2 | 1: 20.0 [20.0–25.1] / 25.1 | 1: 26.8 [23.1–28.0] / 28.0 | 1: 1.9 [1.6–2.7] / 2.7 | - |
| `process.step` | 2: 0.4 [0.4–0.7] / 6.1 | 2: 0.5 [0.5–1.0] / 6.2 | 2: 2.0 [0.5–4.2] / 5.7 | 2: 4.2 [0.6–4.7] / 6.1 | 2: 4.3 [1.3–4.5] / 6.0 | 5.9 |
| `process.terminate` | 1: 0.4 [0.3–5.9] / 5.9 | 1: 7.6 [6.8–7.9] / 7.9 | 1: 5.4 [0.6–8.5] / 8.5 | 1: 4.1 [0.7–5.9] / 5.9 | 1: 7.0 [5.8–9.2] / 9.2 | - |
| `test.run` | 1: 13.5 [13.3–37.5] / 37.5 | 1: 42.7 [8.3–42.7] / 42.7 | 1: 40.0 [7.6–42.9] / 42.9 | 1: 39.8 [7.9–42.9] / 42.9 | 1: 39.8 [9.2–40.4] / 40.4 | 9.6 |

- **TCP costs nothing measurable over the Unix socket on one machine.**
  Raw round trips on one connection (`m9d/measure/raw/raw.txt`, 50 each,
  `kajo run shell.img` release, a Python client): `evaluate` of `3 + 4`
  0.22 ms over the Unix socket, 0.29 over TCP to 127.0.0.1, 0.30 to the
  LAN address; `class.hierarchy` (16 546 bytes) 4.60, 4.73 and 4.75 ms;
  `package.selectors` of Kernel (56 779 bytes) 11.9, 12.0 and 12.0 ms.
  TCP adds about 0.07 ms per request; the reply's bytes are the target's
  work (3.5 to 4.8 MB/s of JSON built), not the link's.
- **In the tools, the reply is read again in the client image.** The same
  `class.hierarchy` takes 29 to 33 ms through `DevClient` (4.7 ms raw):
  the Mac image reads 16.5 KB of JSON in pieces and builds the objects,
  about 0.55 MB/s end to end. That is also why 9c's 2009-class hierarchy
  (190 KB, about 94 bytes a class here too) took 0.33 s locally, and
  this module's gate run of 9c's session measured 326 to 334 ms for it
  again (below). **The 2000-class hierarchy over a link** would cost those
  0.33 s plus 190 KB at the link's rate: 4 to 40 ms at 5 to 50 MB/s of
  Wi-Fi, a tenth of the request at most, so neither the on-demand form
  nor a request per package is needed for the link (the tools' default
  stays push, decided). The phone's own work building the reply is not
  measured (the phone did not run).
- `package.selectors` differs by package: the local session lists Tools
  (361 methods, 11 ms), the remote ones Kernel (2049, 72 to 78 ms).
- **A Bonjour name costs its resolution at the first connect**: the
  session's open step is 0.28 to 0.44 s by name against 31 ms by address
  (dns_sd resolve, then the Mac's `.local` name to its addresses), and the
  request queued behind it shows it (`package.list` max 402 ms,
  `class.hierarchy` max 433 ms). The reconnect resolves again: the
  outage is 1.020 s by name against 1.006 s by address.
- Retried requests (`(retried)`) count from their first send: 1 s of
  backoff, the new connection and session, then the request.

### Sessions and the dropped link

| target | sessions | seconds | client frames missed | reconnects | outage ms | sent again |
|---|--:|--:|--:|--:|--:|--:|
| local (Unix socket, its own image) | 3 | 2.25 [2.20–2.28] | 50 [43–50] | 1 | 1006.4 [1006.0–1006.8] | 2 |
| TCP 127.0.0.1 | 3 | 2.29 [2.27–2.33] | 45 [44–48] | 1 | 1005.8 [1003.7–1008.5] | 2 |
| TCP 192.168.1.10 | 3 | 2.31 [2.28–2.33] | 45 [42–46] | 1 | 1005.6 [1005.1–1007.0] | 2 |
| Bonjour name | 3 | 2.69 [2.55–2.73] | 41 [37–43] | 1 | 1020.5 [1017.0–1022.4] | 2 |
| kajo run, TCP LAN | 3 | 2.29 [2.26–2.31] | 44 [43–46] | 1 | 1006.4 [1006.4–1006.7] | 2 |
| TCP LAN, the target running idle | 18 | 2.33 [2.24–2.38] | 46 [41–51] | 1 | 1007.0 [1004.5–1009.0] | 2 |
| TCP LAN, the target running ring | 18 | 2.42 [2.37–2.46] | 52 [46–57] | 1 | 1006.2 [1003.7–1008.1] | 2 |

- **Every session ended, no failure** (51 in the gate run): the define
  and retry step and the dropped link on every one.
- **The outage is the backoff**: 1.004 to 1.008 s from the loss to the
  new session by address (1 s of wait, then about 5 ms to connect and open
  the session), 1.017 to 1.022 s by Bonjour name. Two requests were
  pending at the loss each time and both were sent again and answered.
- The client shell's missed frames (41 to 57 of about 280) are the
  AppKit windows opening and the debugger's (9c's finding), not the
  link's: the local form misses as many.

Steps (ms):

| step | local (Unix socket, its own image) | TCP 127.0.0.1 | TCP 192.168.1.10 | Bonjour name | kajo run, TCP LAN |
|---|--:|--:|--:|--:|--:|
| open | 39.1 [35.4–46.9] | 32.3 [26.8–34.2] | 30.7 [30.6–30.8] | 380.6 [276.6–441.0] | 31.1 [30.4–31.6] |
| populate.push | 33.5 [33.0–41.6] | 27.2 [25.3–27.3] | 27.1 [26.7–32.9] | 35.5 [34.8–35.6] | 27.1 [25.8–27.5] |
| populate.onDemand | 33.4 [33.3–41.9] | 24.8 [24.8–24.9] | 25.0 [24.9–33.4] | 40.7 [39.8–41.0] | 33.1 [24.9–33.1] |
| tree.push | 1.4 [1.4–7.1] | 6.8 [6.8–9.9] | 6.8 [6.7–6.9] | 1.6 [1.4–1.6] | 6.7 [6.6–6.8] |
| tree.onDemand | 6.8 [1.6–6.8] | 1.3 [1.2–1.3] | 1.4 [1.3–1.5] | 7.0 [1.2–7.1] | 1.2 [1.2–1.3] |
| selectors.request | 15.9 [11.0–19.7] | 72.8 [69.4–80.0] | 78.1 [75.3–78.2] | 76.4 [72.9–83.8] | 72.6 [69.0–81.2] |
| selectors.push.361 | 0.3 | - | - | - | - |
| selectors.onDemand.361 | 9.5 [8.8–10.4] | - | - | - | - |
| select.10 | 191.0 [187.0–214.3] | 139.0 [138.4–157.4] | 156.8 [139.0–156.9] | 139.2 [137.0–149.2] | 148.1 [143.0–154.4] |
| compile | 15.8 [15.6–15.8] | 14.5 [11.9–17.7] | 17.1 [15.2–17.5] | 17.3 [11.3–18.2] | 12.7 [11.5–12.8] |
| test.run | 13.7 [13.5–42.6] | 47.4 [32.9–47.6] | 43.9 [32.0–48.1] | 43.1 [8.0–47.1] | 44.4 [33.3–44.7] |
| error.debugger | 119.5 [79.2–125.4] | 84.0 [74.8–86.1] | 83.7 [74.9–98.3] | 97.1 [90.7–123.3] | 85.0 [82.8–85.8] |
| step | 25.3 [22.9–26.8] | 25.2 [23.3–26.1] | 25.7 [21.9–26.0] | 29.6 [26.4–31.6] | 26.3 [26.2–26.7] |
| fix.proceed | 11.9 [11.1–12.3] | 14.9 [6.8–18.0] | 12.1 [11.7–12.7] | 11.8 [11.7–12.5] | 12.5 [11.3–12.6] |
| define.retry | 197.9 [166.0–204.5] | 210.6 [210.2–222.8] | 210.9 [202.5–224.7] | 202.0 [199.2–218.8] | 202.9 [193.0–207.3] |
| drop.stop | 79.1 [61.2–111.6] | 69.1 [67.1–82.8] | 82.7 [62.3–99.5] | 61.4 [60.8–71.5] | 80.0 [66.6–86.7] |
| drop.reconnect | 1057.9 [1049.7–1088.0] | 1052.2 [1043.8–1060.4] | 1060.8 [1042.3–1068.4] | 1075.3 [1050.0–1082.1] | 1045.6 [1044.3–1069.0] |
| drop.terminate | 6.2 [6.1–6.8] | 14.3 [14.2–19.2] | 8.5 [6.3–14.4] | 6.7 [6.3–7.3] | 14.6 [6.6–22.9] |
| reset | - | 6.2 [6.0–6.2] | 6.5 [5.5–9.2] | 6.3 [6.2–6.3] | 6.1 [5.9–6.2] |
| selectors.push.2049 | - | 10.8 [6.9–18.7] | 1.7 [1.7–7.0] | 6.9 [1.7–7.9] | 7.7 [2.0–9.8] |
| selectors.onDemand.2049 | - | 10.2 [10.0–11.0] | 11.1 [9.8–11.2] | 10.0 [9.6–12.5] | 11.5 [9.4–26.3] |

- **The debugger across the link** (`define.retry`): 198 to 211 ms from
  the doit to the Process going on after the method was defined from the
  Mac's debugger and the send retried, local and remote alike; the class's
  file (`DevSessionTarget.class.st` with `undefinedStep`) was written into
  the client's project directory every time (`m9d/section3/proj-*/`).
- **The dropped link** (`drop.reconnect`): 1.05 to 1.09 s from the drop
  to everything back (the two replies, the stopped Process listed as
  stopped, its debugger's frames fetched again); `drop.stop` 61 to 83 ms
  (a doit stopping, the debugger open with its frames).
- 9c's steps against a target over TCP take what they take locally; the
  local `select.10` is longer (191 against 139 to 157 ms) because there
  the image is the target too.

### The serving target's frames

The macOS shell serving over TCP while it runs 9a's scenario, its window
20 s at 120 Hz, with a client running the scripted session three or four
times in the window, with no client, and the plain 9a scenario (not
serving), 2026-11-05 12:42 to 12:53, thermal fair:

| row | runs | missed of 2400 | max gap ms | longest turn ms | requests served in the window | KB written | `deliver` mean / max µs | most queued KB | main thread CPU ms per 10 s |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| idle, a client | 3 | 0 | 8.4 | 3.2 [3.1–3.2] | 374 [371–376] | 1466 | 4.7 / 29.1 [21.5–31.9] | 55.5 | 2704 [2700–2722] |
| idle, no client | 3 | 0 | 8.4 | 3.3 [3.2–3.3] | 0 | 0 | - | 0 | 3574 [3568–3578] |
| idle, 9a's scenario (not serving) | 3 | 0 | 8.4 | 3.2 | - | - | - | - | 3577 [3569–3593] |
| ring, a client | 3 | 0 | 8.4 | 3.7 [3.4–3.7] | 385 [382–385] | 1473 | 6.6 / 35.0 [25.0–86.5] | 55.5 | 2064 [2063–2076] |
| ring, no client | 3 | 0 | 8.4 | 3.1 [3.1–3.5] | 0 | 0 | - | 0 | 2057 [2057–2057] |
| ring, 9a's scenario (not serving) | 3 | 0 | 8.4 | 3.1 [3.0–3.1] | - | - | - | - | 2067 [2056–2075] |

- **No frame missed** in any row, with or without a client, idle or
  ring, as in 9a's Mac rows (0 of 1200 in both, 10 s windows). The
  protocol Process runs each request in a Process of its own on the
  background workers; the requests that touch views hop to main within
  the turn budget, and the longest turn on main stayed 3.1 to 3.7 ms.
- **The writer never blocks a VM thread**: `deliver` (routing a line and
  queueing it on the connection's writing queue) took 4.6 to 6.6 µs on
  average and at most 86.5 µs; at most 55.5 KB waited in a writing queue
  (the Kernel selectors' reply). The socket is the writing queue's.
- Serving costs nothing without a client (the no-client rows equal the
  plain scenario). With a client the idle main thread used less CPU (2.7
  against 3.6 s per 10 s) for the same frame load; faster clocks while a
  second process is busy is a guess, not a measurement (9c's idle note).
- Thermal: the Mac's state was fair in every row of the gate run and
  nominal in every row of the first run; the phone's states (9a: serious
  from its first ring row) are not measured.

### On the devices

2026-11-06 00:17 to 00:31, on 79ef19d (module 10's VM and kernel, the iOS
spec at device family 1 and 2, the two script fixes below), the iOS shell
Release as `scripts/device.sh build` makes it.

**What ran.** The iPhone 13 Pro (iOS 27.2) built, signed and installed;
the kernel tests ran on it (below); the shell served the protocol over
TCP and showed its pairing screen in every serving launch; its frames
while serving were measured against the same scenario not serving.
**What did not**: every row with a client (round trips over Wi-Fi,
define-and-retry across the link, the dropped link, the phone's frames
with a client), on the iPhone and on the iPad, and everything on the
iPad:

- `scripts/remote-session.sh device <out> lan-1 idle lan 1` stopped at
  the token: `device.sh token` found no `_kajo-dev._tcp` service, and
  `dns-sd -B` on the Mac saw none in any serving launch while it listed
  the network's other services. From the agent's session, `ping` and a
  TCP connect to the phone's Wi-Fi address (192.168.1.103) and to its USB
  link (169.254.53.71) answered "No route to host", as did every other
  LAN host but the router (the router and the internet answered), with
  the agent's sandbox on and off: macOS's local network privacy for the
  session. 9d's Mac-to-Mac rows never met it, because the Mac's own LAN
  address is not another host. The owner allows Local Network for the
  terminal the sessions run from (System Settings, Privacy and Security)
  and taps Allow on the phone if iOS asks for Kajo; nothing was answered
  or changed here.
- The iPad: `DEVICE=00008027-0012592C0185002E scripts/device.sh build`
  failed before compiling: "No Accounts: Add a new account in Accounts
  settings" and "Provisioning profile 'iOS Team Provisioning Profile:
  dev.katajamaki.kajo.shell' doesn't include the currently selected
  device". The iPhone's profile is on the Mac; adding a device to it needs
  Xcode's account (or the iPad registered in the team's portal), the
  owner's.

**Two bugs in the scripts, fixed** (written in 9d, never run against a
phone): `device.sh token` copied the token file onto a directory, which
`devicectl` refuses ("Cannot open destination file ...: Is a directory"),
so no token ever arrived; and `remote-session.sh device ... lan` took the
first address of the phone's list, which is the USB link's 169.254 one
(the list is 169.254.53.71, 192.0.0.6, 192.168.1.103 and four IPv6), so a
"lan" row would not have crossed Wi-Fi. It now takes the address on the
Mac's own network. The phone's console output carries no token.

**The phone's frames while serving** (`device.sh serve` as
`remote-session.sh device` launches it for its control row, sessions 0:
`mode=serve protocol=tcp:47100`, 20 s after 1 s of warmup, the default
5 background workers and offload young collection), against the same
scenario not serving (`mode=scenario`, the same window), three runs of
each interleaved with 20 s between launches; `remote-report.py` and the
result lines, with the Mac-to-Mac no-client rows of the table above and
9a's phone rows (10 s windows at thermal serious) beside them:

| row | runs | missed of 2400 | max gap ms | longest turn ms | main thread CPU ms per 10 s | main stopped for others ms per 10 s | power W | peak MB | thermal start→end |
|---|--:|--:|--:|--:|--:|--:|--:|--:|---|
| iPhone, idle, serving, no client | 3 | 0 | 8.4 | 3.4 [3.3–3.8] | 3708 [3708–3714] | 0 | 0.016 | 33 | nominal, nominal, fair |
| iPhone, idle, not serving | 3 | 0 | 8.4 | 3.3 [3.2–3.3] | 3715 [3712–3717] | 0 | 0.015 | 32 | nominal |
| iPhone, ring, serving, no client | 3 | 0 | 8.4 | 4.5 [4.4–5.2] | 2671 [2574–2744] | 48.3 [46.4–49.5] | 4.1 [3.9–4.4] | 575 [561–590] | nominal |
| iPhone, ring, not serving | 3 | 0 (2399 frames counted once) | 8.4 | 4.9 [4.9–5.1] | 2837 [2768–2924] | 52.4 [48.8–54.4] | 3.7 [3.5–3.8] | 591 [585–598] | nominal, nominal, nominal→fair |
| 9a's iPhone rows (10 s, serious): idle / ring offload | 3 | 0 / 0 of 1200 | 8.4 / 8.3 | - | - | 0.0 / 80.5 | 0.016 / 1.8 | 31 / 557 | serious |
| Mac to Mac: idle / ring, no client | 3 | 0 / 0 | 8.4 / 8.4 | 3.3 / 3.1 | 3574 / 2057 | - | - | - | fair |

- **Serving costs the phone nothing without a client**: the serving rows
  equal the plain ones (no frame missed, the same turns, CPU and power),
  as on the Mac. The listener and the pairing screen are idle work.
- The ring at thermal nominal stopped the main thread 46 to 54 ms per
  10 s, against 9a's 68 to 83 at serious; 0 frames missed either way.
  The process drew 3.5 to 4.4 W under the ring at nominal against 9a's
  1.8 at serious (a hot phone runs slower clocks).
- The phone stayed nominal for ten of the twelve launches (fair from the
  last idle serving row; the build, the tests and three probe launches
  came first).

**The kernel tests on the iPhone** (`scripts/device.sh tests`, c2de63f,
module 10's kernel): 202 tests, **198 passed, 1 failed, 3 errors** in
5348 ms, thermal nominal, peak 70 MB. All four are `ViewWrapperTest`
(9c's second round of wrappers): `testMenusAndToolbars` and
`testOutlinesAndTables` ("the view call #create failed": UIKit has none
of those kinds, 9c's known gap), `testATextViewsSelectionStylesAndKeys`
("the view call #get failed", `get: 'styles'`), and
`testTheEventLoopsKindActionsAndTimers` (its "without a host a timer
cannot be asked for" assertion fails where a shell is the host). The
macOS shell's tests mode on the same commit fails three of them the same
way (199 of 202: the text view's `get`, `testOutlinesAndTables`'s `get`,
the timer assertion): the test is written for the headless host, and
9a's and 9c's shell runs predate it. Not changed here (the code is not
this run's to change).

**The question 9d left for the phone** (whether the class tree wants the
on-demand form or a request per package over Wi-Fi) is still not
answered by a measurement: no request crossed Wi-Fi. The Mac-to-Mac
reasoning stands (the reply's bytes cost a tenth of the request at most
next to building and reading the JSON, so push stays the default) until
`remote-session.sh device` runs.

### The kernels against the starting commit

The starting commit's `kajo` (a69591d, from a worktree) against this
module's (a487630), both built `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
`--slice-ms 0`, 2026-11-05 12:53 to 12:58; median (min to max) ms; every
checksum equal on both sides and the published one (`m9d/bench-ab.txt`).

| kernel | workers | a69591d ms | 9d ms | 9d / start | checksum |
|---|--:|--:|--:|--:|---|
| alloc | 1 | 2946.0 (2933 to 2968) | 2941.2 (2933 to 2943) | **0.998** | 41950911 |
| alloc | 8 | 477.8 (445 to 498) | 476.3 (462 to 494) | **0.997** | 42008248 |
| arith | 1 | 2548.7 (2536 to 2558) | 2547.3 (2534 to 2556) | **0.999** | 372800000 |
| arith | 8 | 340.1 (338 to 361) | 337.7 (336 to 355) | **0.993** | 372800000 |
| fib | 1 | 1692.1 (1691 to 1698) | 1691.7 (1688 to 1701) | **1.000** | 24682992 |
| fib | 8 | 227.2 (219 to 242) | 225.2 (217 to 233) | **0.991** | 24682992 |
| ivars | 1 | 1969.1 (1968 to 1978) | 1973.3 (1969 to 1975) | **1.002** | 36383626 |
| ivars | 8 | 261.6 (252 to 280) | 260.9 (252 to 275) | **0.997** | 71714128 |
| sends | 1 | 2578.3 (2577 to 2592) | 2570.6 (2562 to 2584) | **0.997** | 1066666666666668 |
| sends | 8 | 338.9 (331 to 365) | 336.7 (332 to 361) | **0.994** | 133333335000001 |
| Smalltalk closures | 1 | 3804.9 (3784 to 3808) | 3799.0 (3788 to 3807) | **0.998** | 210210000 |
| Smalltalk closures | 8 | 503.6 (484 to 522) | 500.3 (483 to 507) | **0.993** | 209214000 |
| Smalltalk ivars | 1 | 1966.9 (1966 to 1970) | 1967.4 (1966 to 1969) | **1.000** | 36383626 |
| Smalltalk ivars | 8 | 257.3 (252 to 264) | 256.3 (253 to 271) | **0.996** | 71714128 |
| Smalltalk sends | 1 | 2320.2 (2313 to 2334) | 2308.1 (2293 to 2323) | **0.995** | 1066666666666668 |
| Smalltalk sends | 8 | 303.8 (300 to 326) | 306.4 (300 to 314) | **1.009** | 133333335000001 |
| storeheavy | 1 | 2406.5 (2395 to 2409) | 2403.2 (2403 to 2414) | **0.999** | 512000 |
| storeheavy | 8 | 321.9 (308 to 334) | 322.8 (310 to 331) | **1.003** | 512000 |

Within noise: 0.995 to 1.002 on one worker, 0.991 to 1.009 on eight.
`interpret` is the same code in both aligned binaries: its disassembly
(1320 lines) differs only in the page offsets of the jump table's `adrp`
(8 lines). An earlier A/B on 5479f7e (the transport's first commit) gave
0.994 to 1.007 on one worker and 0.960 to 1.064 on eight with overlapping
ranges; the VM did not change between the two.


## Changes to earlier modules

- **9a**: `ShellEventKind.targets` (17) and `UIEvent kinds` `#targets`;
  `ShellPlatform` gains `showPairing` and `onNewToken` (both shells);
  `ShellRuntime.startServing` (9b's serving, shared by the Unix socket and
  TCP) and `serveTCP`; `mode=serve`; the scenario's `protocol=tcp[:port]`,
  `tokendir=`, `bonjour=` and its `served_*` fields; the iOS shell's
  pairing panel; `NSBonjourServices` and `NSLocalNetworkUsageDescription`
  in its `Info.plist` and `project.yml`; `scripts/device.sh serve` and
  `token`.
- **9b**: `ProtocolServer` over TCP, the failed-pairing limits (a wrong
  token no longer closes the connection at once: three do), a
  replaceable token, `dropConnections`, counters (`ServerStats`);
  `ProtocolClient(address:)` and **a fix**: `ProtocolClient.close` closed
  its descriptor again from `deinit`, so a client released after its
  `close` could close a descriptor another thread had been given since (it
  closed a Bonjour resolver's socket in the middle of a resolve in this
  module's suite); it now shuts down and closes once. `DevTarget` takes
  `.tcp(port:loopbackOnly:advertise:name:)`; the CLI's `--target` takes
  any address or a target name; `kajo run --protocol tcp[:port] --name`.
- **9c, tokens (the owner's decision of 2026-11-05, answering 9c's
  question 5)**: no token enters the image, not even a typed one. The
  target picker's token field is gone (its Add takes an address only; a
  Pair button asks the host), `ClientTransport connect:client:package:project:`
  and primitive 164's `connect` lost the token argument (a five-argument
  `connect` is refused), `DevClient connect:name:client:package:project:`
  and `DevTools connect:name:` / `connect:name:project:` likewise;
  `ClientTransport pair:` and the host's `pairing` op are new
  (`ClientHost.setSecretPrompt`, `ShellPlatform.askSecret` in both
  shells); `TargetPickerModelTest` pairs through a fake, and
  `PhoneTransportTests>>aTokenIsPairedInTheHostNeverInTheImage` pairs a
  TCP target through the real host with a fake secure field and connects
  by name.
- **9c**: `ClientHost` (addresses, browsing, the `targets` event,
  `dropConnections`); `DevClient` (reconnect and retry,
  `notRetried`, `outages`, `retried`, `reconnects`, `onTargetsChanged:`,
  `openConnection` and `after:do:` for tests); `FakeDevClient` (a link that
  drops); `DevTools connect:name:token:project:`, `openTarget:name:project:`,
  `reconnected:`; `TargetPickerModel` (the reconnecting state, the
  `targets` event, its sources injectable for its test); `BrowserModel
  selectorsLoaded`; `DevSessionBench` (the remote form, `reset`,
  `define.retry`, the dropped link; a class without selectors no longer
  stalls `select.10`); `DevClientTest>>testTheConnectionsEndFailsWhatIsPending`
  closes the client first (a dropped link reconnects now).

## Deviations from the brief

- **The phone did not run.** Its signed build could not be made (the
  status note above); the iOS shell's code was compiled (`just apps`, 0
  warnings) but not run, and every phone row of section 3 is replaced by
  the same row Mac to Mac: the macOS shell in `mode=serve` as the target
  (the iOS shell's code path in `KajoShellCore`), `kajo run --protocol
  tcp` as the second target the brief names, loopback, the Mac's LAN
  address and its Bonjour name as the three ways to reach it.
- **The serving rows' window is 20 s**, not 9a's 10 s, so that three or
  four whole sessions fit in it; the frames are counted of 2400.
- **A wrong token no longer closes the connection at once**: the brief's
  "three failed `session.open` and the connection closes" needs the
  connection to stay open after the first; on the Unix socket too, one
  rule for both. A first request that is not `session.open` still closes
  it, and counts towards the listener's limit like a wrong token.
- **dns_sd for advertising and resolving, `NWBrowser` for browsing.**
  `NWListener` advertises only a socket it owns (the brief's one accept
  loop is a BSD socket's), and resolving a browsed service to a host and
  port for that same socket code is dns_sd's `DNSServiceResolve`. A
  service found on the loopback interface resolves to the machine's name,
  whose addresses a loopback-only listener does not take, so it is
  reached at `localhost`.
- **`NSLocalNetworkUsageDescription` is in the iOS shell's `Info.plist`**
  although the shell does not browse (the brief: "if the iOS shell ever
  browses"): local network privacy is documented to cover advertising and
  accepting local connections too, and iOS cannot ask without the string.
  Unverified on the phone.
- **The Mac's serving shell keeps its token in memory** unless
  `tokendir=` gives it a store (the measurement's way to hand it to the
  client, as `scripts/device.sh token` copies the phone's from its
  container); the brief's per-install file is the iOS shell's.
- **Pairing is the host's secure field** (the owner's decision during
  the module, beyond the brief): 9c's typed-token path through the target
  picker and `connect`'s token argument are gone.
- **The remote session's package is Kernel** (2048 methods) rather than
  the 2000-class image's Generated: the phone runs the shell image. The
  local session's own selectors step lists Tools (359), so
  `package.selectors` differs by package between the two columns.
- **The session gained steps in both forms** (`define.retry`, the dropped
  link) and a `reset` step in the remote form; 9c's steps are unchanged
  but for `select.10` skipping a class without selectors (a kernel class
  can have none; the Generated ones all had eleven).
- **`mode=serve` is a scenario serving over TCP**, `scenario=idle` by
  default, not a mode of its own: the brief's frames are a scenario's
  frames while serving, and a phone left serving with nothing to show is
  the idle scenario.

## Tests

Swift: `KajoVMTests` as at the start (312); `KajoCompilerTests` gains
`PhoneTransportTests` (6, 82 in all, 76 at the start):
`theServerServesTCPWithTheTokenRuleAndTheLimits` (a session over TCP on
127.0.0.1 and through `localhost`'s ::1-then-127.0.0.1, two wrong tokens
answered and the third closing the connection, seven more failures making
the listener refuse every connection, the right token included, a minute
of the test's clock later serving again, the counters),
`aNewTokenEndsEverySession`, `aTokenIsPairedInTheHostNeverInTheImage`
(the tools ask the host to pair a TCP target by name, a fake secure field
types the token, the host holds it, the tools connect; a `connect` with a
token argument is refused), `bonjourFindsAListenerTheTestStarts` (a
target advertised on the loopback interface, `ClientHost`'s browser
listing it and posting a `targets` event, the Swift client and the client
transport connecting by its Bonjour name, the token from a targets file
never in the reply the image gets), `theAddressFormsTheTargetsFileAndTheTXTRecord`,
and `theToolsReconnectAfterADroppedLink` (a development image's tools in a
test shell on a TCP target: a doit stops there, the client transport drops
its sockets, two requests go out on the dead link, the client reconnects
once, both are answered, the Process is still stopped in the target and
its debugger fetched its frames again). `ToolsTests`' shell can drop its
client transport's sockets on a Transcript line. Smalltalk: `tools/` has
29 SUnit tests (25 at the start): `DevClientTest` 11 (three new: a
dropped link reconnects and sends again what may be sent again, the wait
grows and `close` ends it, a refused session is not reconnected) and
`TargetPickerModelTest` 1 (new: a target without a token says so and is
paired through the host, the targets listed again, a target's state
through a dropped link). The kernel's 200 SUnit tests as at the start.
Waits are bounded (60 s per condition, 30 s for Bonjour, 10 s per
connect); the assertions are on what happened, and the minute of the
listener's pause is the test's own clock.

## Broken variants run by hand

Each on the final code with one rule broken, then put back; the outputs
are kept with the gates' (`m9d/broken/`).

| rule | broken variant | test | result |
|---|---|---|---|
| a dropped link reconnects | `DevClient>>lost:` ends the client whatever the cause | `DevClientTest`, `PhoneTransportTests/theToolsReconnectAfterADroppedLink` | fails: "Expected #reconnecting but was #lost", "the collection is empty" (no timer), and "reconnected never held: client nil" (the target saw 2 sessions, not 3) |
| what may have run is not sent again | `notRetried` answers `#()` | `DevClientTest>>testADroppedLinkReconnectsAndSendsAgainWhatMayBe` | fails: the doit is kept and sent again; its error block never runs ("nil does not understand #includesSubstring:") |
| three wrong tokens close a connection | the reader keeps a connection open after any refusal | `PhoneTransportTests/theServerServesTCPWithTheTokenRuleAndTheLimits` | fails: "an error was expected but none was thrown" (the fourth attempt is answered) |
| ten failures stop the listener | the pause never starts | the same | fails: `isRefusing` false, no `onRefusing` call, the right token opens a session during the minute, `refusedConnections` 0 |
| a client closes its descriptor once | `ProtocolClient.close` without the guard (9b's) | `PhoneTransportTests/(theServer|bonjour)` | fails: "no Bonjour service kajo-test-... answered within 10.0 s": a client released after the limits test closed its descriptor again, which by then was the resolver's socket of the next test (passes alone) |

## Unsafe surface

Lines with `unsafe` (comments excluded), on the final commit against
a69591d, counted the same way on both: `Sources/KajoVM` 4756 as at the
start (the new event kind is an enum case). `KajoDev` 83 against 20:
`Transport.swift` 60 (socket options, `getaddrinfo` and the non-blocking
connect with its poll, dns_sd's register, resolve and their C callbacks,
the `Unmanaged` boxes those callbacks get, `getifaddrs`), `Server.swift`
19 against 12 (the TCP listener's socket options, `bind` and
`getsockname`), `Client.swift` 2 against 4 and `ClientHost.swift` 2
against 4 (their connects moved into `openStream`). `KajoShellCore` 20
against 16: `Serving.swift` 4 (the token file's `unlink`, `open` with
mode 0600, `write`, `rename`). `BonjourAdvertiser` is `@safe` over its
`DNSServiceRef` and `Unmanaged` box, released once in `stop`. The apps'
Swift is not built with strict memory safety. The clean build has 0
warnings (Gates).

## Hot-path check

Nothing of this module is on the checked paths: the interpreter, the
primitives and the VM's threads are untouched (one enum case in the
shell's public surface). `just arc-check` (Gates) and the bench A/B
(Measurements) hold; `interpret` is the same code in both aligned
binaries.

## Not done

- **The phone's rows with a client.** Since 2026-11-06 the iOS shell
  builds, signs and serves on the iPhone 13 Pro, with its pairing screen
  and token file, and its frames while serving with no client are
  measured ("On the devices"); its Bonjour advertisement was never seen
  on the network, and the Mac's tools could not reach it (local network
  privacy on the Mac, probably the phone's permission too; "On the
  devices"). So section 3's rows on the phone are still not run: the round trips over Wi-Fi, the
  phone's frames while serving against 9a's phone rows, the debugger and
  the dropped link across Wi-Fi, the phone's thermal state per row, and
  whether iOS asks for local network access. The commands are ready:
  `scripts/device.sh build`, then `scripts/remote-session.sh device <out>
  <tag> idle|ring lan|bonjour <sessions>` per row (it serves through
  `scripts/device.sh serve`, takes the token with `scripts/device.sh
  token` and runs the sessions from the macOS shell), with a bounded
  cooling wait between rows as 9a's matrix had none. `device.sh serve`
  ran (12 launches); `token` copies the token since its fix and has not
  yet found the service by name. The iPad Pro (iPadOS 26.7.2, device
  family 2 since 2026-11-06) ran nothing: its build waits on Xcode's
  account to add it to the profile.
- **TLS** (the owner's question below) and any encryption; USB
  tunnelling; the developer UI on the phone; more than one Mac's tools on
  one phone at a time beyond what the server already allows (it accepts
  any number of sessions; nothing coordinates them).
- **The Swift client does not reconnect**: the CLI opens a connection per
  command; the MCP server opens a new one when its connection is gone
  (9b), without retrying the call that failed.
- **The inspector's handles do not survive a dropped link**: they are the
  old session's (9b releases them at its end); an inspector open across a
  reconnect answers errors for its handles.
- **A retried command on a stopped Process may answer an error although
  the first one acted** (the Process is no longer stopped); the tool
  shows that error. The reply of the first is lost with the link.

## Open questions for the owner

1. **TLS on the owner's network.** The link is plain TCP: the token and
   every request and source cross the network readable. Suggested, if
   wanted: TLS with the pairing token as a pre-shared key
   (Network.framework's `sec_protocol_options_add_pre_shared_key`), which
   encrypts and authenticates both ends with nothing but the token the
   phone already shows: no certificates, no keychain. It means moving the
   transport from BSD sockets to `NWConnection` and `NWListener` on both
   sides (the line reader and writer stay). Provisional: plain TCP.
2. **Should the token expire?** It is stable per install until the New
   token button. Provisional: no expiry.
3. **More than one session at a time on the phone?** The server takes
   any number (the measurement's client and its reconnect overlap for a
   moment). Limit it to one developer session plus agents, or leave it?
   Provisional: any number.
4. **Should the phone ever serve without the launch argument** (a switch
   in the app)? Provisional: no; serving is a launch argument of a
   development image.
5. **Signing on the mini.** The signed iPhone build waits on a keychain
   prompt on the Mac's screen (codesign at 0 percent CPU, twice, for
   minutes); the 9a and 9c device runs signed. The phone's rows need it
   answered (or the key's access set to allow codesign) by the owner;
   then `scripts/remote-session.sh device` makes the rows.
   *2026-11-06*: codesign is allowed and the iPhone builds, signs and
   installs (about a minute). Two things remain before the rows run:
   Local Network access on the Mac for the session that starts the
   client (and on the phone for Kajo, if it asks), and Xcode's account
   for the iPad's profile ("On the devices").
6. **The not-retried requests.** `evaluate`, `process.evaluate`,
   `process.step` and `test.run` fail at a dropped link instead of being
   sent again; the tool shows the error and the developer repeats the doit
   if wanted. Right, or should a doit be sent again too (at most twice)?
   Provisional: fail them.

### The owner's answers (2026-11-05)

1. **TLS**: plain TCP stays for now; TLS with the pairing token as a
   pre-shared key (both sides on Network.framework) is a later module.
2. **Token expiry**: none; the token is stable per install until the New
   token button.
3. **Sessions on the phone**: any number. A cap would refuse the
   reconnect that overlaps the connection it replaces, and agents share a
   phone with the developer's tools; the token and the failure limits are
   the protection. A session list with a disconnect button is the tool if
   a forgotten client ever matters.
4. **Serving without the launch argument**: no; serving stays an explicit
   act of a development image.
5. **Signing**: the owner clears the keychain prompt on the mini, then the
   phone's rows run with `scripts/device.sh build` and
   `scripts/remote-session.sh device`.
6. **The not-retried requests**: fail them, as built. A resend cannot tell
   a doit that never arrived from one whose reply was lost, so it guesses
   wrong exactly when the doit had side effects. If doits are ever
   retried, the form is a request id the target remembers and answers
   from, a protocol change, not a flag.

## What a later module needs

- **The developer UI on the phone** (if ever): the second round of view
  wrappers on UIKit (outline, table, split, scroll, toolbar, menus; only
  the text view's exists on iOS), `ClientHost` in the iOS shell (it is
  `KajoDev`, which builds for iOS; browsing from the phone needs
  `NSBonjourServices` for the type, which is there, and the local network
  permission), and a development image bundled for the phone with
  `tools/` in it.
- **Large replies**: the owner chose a large-object space in the VM as
  a later module; 9c's `LargeArray` and pieced lines stay as they are. No
  reply over the link needed more: the largest the session asked for
  (`package.selectors` of Kernel, 57 KB) travelled in pieces as in 9c.
- **TLS** (question 1): one place to change, `openStream` and the
  server's listener, if both move to Network.framework with a pre-shared
  key from the token; `ClientHost`, `ProtocolClient` and the reader and
  writer threads keep their line interface. The Bonjour advertisement can
  stay dns_sd's. A TCP connection that sends anything before a TLS
  handshake would be refused at the first line, as now.
- **The phone's measurements** first: the round trips over Wi-Fi decide
  whether the class tree wants the on-demand form or a request per
  package (Measurements: on the Mac the reply's bytes cost nothing next
  to the JSON work in both images).

## Gates

The code is a487630's; this doc, `docs/CONTEXT.md`, ADR 0011 and
`docs/modules/developer-ui.md` were edited in the working tree during the
run and committed after it (`gates.log` counts 4 files changed, all under
`docs/`). Every gate ran on a487630, Mac mini (M2 Pro), swift.org 6.4.2
first on PATH, Xcode 27.2 for the apps, 2026-11-05 10:37 to 12:58, every
output in a file, each step logged with the commit it ran on. "Load" is
twelve `yes` busy loops, kept at twelve throughout (topped up every 20 s
while a run lasts past their 1500 s). A first run of every gate on
84869f4 was stopped after ThreadSanitizer (312 + 81 passed, 0 reports,
and the plain and loaded suites passed) when the owner's pairing decision
came; everything was run again on a487630.

| gate | result |
|---|---|
| `swift test` | 312 + 82 passed, 234 + 79 s |
| under load (12 busy loops) | 312 + 82 passed, 265 + 97 s |
| ThreadSanitizer | 312 + 82 passed, 0 reports, 497 + 1985 s |
| ThreadSanitizer under load | 312 + 82 passed, 0 reports, 668 + 2456 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release in 135 functions, `interpret` 1056 instructions, one indirect branch and one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 312 + 82 passed |
| `just model-check` | 28 + 5 + 15 passed |
| `just soak` | passed: 1000 seeds under every configuration, no failing seed; the snapshot modes saving 762 to 983 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.32 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 3.62 million runs, no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 0.89 million runs, no crash |
| `just fuzz protocol 600` | libFuzzer build ok, 1.41 million runs (each line also as an address, a targets-file line and a TXT record), no crash |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| clean build | exit 0, 0 errors, 0 warnings (11 s from an empty scratch path: the toolchain's compilation cache, as in 8e and 9b; `just ios-check` typechecks every KajoVM file with strict memory safety from nothing) |
| 9c's scripted session on the macOS shell (`just mac-shell`, local target) | 12 launches (three each of the 2000-class session with no load and with the storm, typing with the storm and with none), every result line written, no failure; 9c's numbers hold: `class.hierarchy` of 2009 classes 326 to 334 ms (9c 329), `package.selectors` 640 ms (657), typing with the storm p50 4.9 ms, 1 frame missed of 1259; the session is 5.7 to 5.9 s now against 3.7 to 3.9 (the two new steps, 1.9 to 2.0 s with 11 to 14 frames missed; drop.reconnect is 1.33 to 1.41 s there, the 2009-class hierarchy being one of the two requests sent again) |
| section 3, Mac to Mac (`scripts/remote-session.sh mac` and `kajo`) | 51 sessions, no failure; 18 serving rows, 0 frames missed in each; tables under Measurements |
| section 3 on the phone | **not run**: the iPhone build could not be signed (the status note); 2026-11-06 on 79ef19d: built, signed, served 12 launches with 0 frames missed, the client rows blocked by local network access, the iPad not built ("On the devices") |
| bench A/B | within noise (Measurements) |

(312 is `KajoVMTests`, 82 `KajoCompilerTests`, whose kernel-image suite
runs the kernel's 200 SUnit tests and `ToolsTests` the tools' 29.) The four
fuzzers ran at the same time, one core each. The broken variants
(`m9d/broken/`) ran on 84869f4 before the pairing change, which touches
none of the rules they break.


## Commands

```zsh
kajo run shell.img --protocol tcp --name kajo-mac          # serve on TCP, advertised; prints the port, addresses, token
kajo eval --target tcp://192.168.1.10:<port> '3 + 4'       # the token from KAJO_TOKEN or the targets file
kajo eval --target bonjour:kajo-mac '3 + 4'
printf 'phone\tbonjour:<name>\t<token>\n' > ~/.kajo/targets; chmod 600 ~/.kajo/targets
kajo debug --target phone list; kajo mcp --target phone
just device serve out.txt scenario=idle seconds=20          # the phone serving (mode=serve protocol=tcp)
just device token targets.txt                               # its token into a targets file (mode 0600)
scripts/mac-shell.sh run out.txt mode=devsession classes=0 target=phone targets=targets.txt project=proj
scripts/mac-shell.sh run out.txt mode=serve scenario=idle protocol=tcp:47100 tokendir=tok
scripts/remote-session.sh device out lan-1 idle lan 1        # the phone, once it signs
scripts/remote-session.sh mac out idle-client-1 idle lan 6 seconds=20
python3 scripts/remote-report.py out
swift test --filter PhoneTransportTests
```
