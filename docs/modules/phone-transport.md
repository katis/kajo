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

**2026-11-06 07:16 to 07:45, the client rows.** With Local Network
allowed on the Mac and the iPad signed, section 3 ran on both devices:
74 sessions from the Mac's tools over Wi-Fi (51 to the iPhone 13 Pro by
address and by Bonjour name, 23 to the iPad Pro by address), every one
ended with no failure, the debugger's define-and-retry and the dropped
link included, and neither device missed a frame while serving a client,
idle or under the ring. Small requests take 4 to 10 ms over Wi-Fi, the
debugger's define-and-retry 0.23 to 0.31 s, a dropped link is whole again
in 1.18 to 1.21 s. The iPad's Bonjour advertisement was not seen that
morning (its local network permission); the owner granted it the same day
and the iPad's rows by name ran at 11:44 to 11:51: 22 sessions by name
beside 23 by address, none failed, the name costing nothing after the
first connect ("On the devices"). The class tree keeps the push form.

New: `Sources/KajoDev/Transport.swift` (the address forms, one stream
opener for every transport, the TXT record, Bonjour advertising,
resolving and browsing, the machine's addresses),
`Sources/KajoShellCore/Serving.swift` (a shell serving over TCP, the
pairing token kept per install, the pairing screen's contents), the
pairing screen in `apps/KajoShell-iOS/Sources/IOSShell.swift` (both moved
by module 11a to `Sources/KajoAppDevelopment/Serving.swift` and
`Pairing.swift`, `docs/modules/app-project.md`),
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
only when asked: no launch argument, no listener. (The shells keep this.
For a generated app module 11a made serving a property of the Debug
build, from launch with no argument, as the owner decided on 2026-11-05;
`docs/modules/app-project.md`.) The iOS pairing screen
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

**The client rows, 2026-11-06 07:16 to 07:45**, on d70cda2's build of the
iOS shell (the phone and the iPad as `scripts/device.sh build` made them
that day) and the macOS shell as client on the mini's display, Local
Network allowed for the session by the owner. `scripts/remote-session.sh
device <out> <scenario>-<form>-<run> <scenario> <form> 6`, sessions
bounded by the script's 14 s window (4 or 5 a launch), the target in
`mode=serve protocol=tcp:47100` for 20 s after 1 s of warmup with the
default 5 background workers and offload young collection, three runs of
every row interleaved with the control row (sessions 0) per scenario, 10 s
between launches; the iPhone 07:16 to 07:27 (`iphone-remote/`), the iPad
07:38 to 07:45 (`ipad-remote/`) after a 5 minute cooling wait; tables
by `scripts/remote-report.py` per device. The iPhone 13 Pro (iOS 27.2) at
192.168.1.103 and by its Bonjour name "Joni’s iPhone"; the iPad Pro
12.9-inch 3rd generation (iPadOS 26.7.2) at 192.168.1.55, **by address
only**: its `_kajo-dev._tcp` advertisement was never seen (below). The
Mac at 192.168.1.10 on the same network.

**What ran**: 51 sessions against the iPhone (26 by address, 25 by name;
idle and ring) and 23 against the iPad (by address), **every one ended
with no failure**: the define-and-retry step and the dropped link on every
one, the class file written into every launch's project directory. The
serving device kept every frame in all 30 serving launches.

**The iPad's Bonjour name never appeared.** In every iPad serving launch
the shell printed `serving=tcp port=47100 addresses=169.254.48.14,
192.168.1.55,...` and its pairing screen, `ping 192.168.1.55` answered
(19 to 45 ms), but `device.sh token`'s 5 s browse and a separate 10 s
`dns-sd -B _kajo-dev._tcp local` while it served saw no service, where the
iPhone's appeared in every launch. The likely cause is iPadOS's local
network permission for Kajo, which the iPad may be asking for on its
screen; nothing was answered or changed here. The token step of
`remote-session.sh` waited for the Bonjour name even in the lan form (the
name is only written into the targets file, never used by address), so
the iPad's first lan rows stopped there; fixed in 7bdb024 (the lan form
passes a placeholder name to `device.sh token`), which does not change
what the iPhone's lan rows did. The iPad's Bonjour rows were therefore
not measured that morning.

**The iPad's Bonjour rows, 2026-11-06 11:44 to 11:51.** The owner approved
the iPad's local network prompt; a 10 s `dns-sd -B _kajo-dev._tcp local`
then showed "Joni’s iPad" while it served. The same script, the iPad's
shell still the morning's build (d70cda2's code) and the same Mac client,
three runs of idle and ring by address and by name interleaved, 10 s
between launches, thermal nominal throughout (`ipad-bonjour/`; a first
attempt at 11:39 is void, its script pointed the Mac client at the iPad's
build directory and no client started). 45 sessions, 22 by name and 23 by
address, **none failed**; the iPad missed 0 of 2400 frames in each of the
12 serving launches (longest turn 3.6 to 3.7 ms idle, 6.2 under the ring).
p50 of the sessions' p50s, ms [range]:

| | idle, by name | idle, by address | ring, by name | ring, by address |
|---|--:|--:|--:|--:|
| sessions | 11 | 11 | 11 | 12 |
| `class.definition` | 6.3 [5.4–9.5] | 6.1 [5.1–7.5] | 9.2 [7.7–14.0] | 9.3 [8.1–10.6] |
| `class.hierarchy` | 54.7 [44.8–408.2] | 58.9 [43.5–126.9] | 48.2 [41.4–82.9] | 56.0 [44.7–126.2] |
| `package.selectors` | 96.9 [82.1–572.8] | 108.4 [83.5–195.6] | 99.0 [91.2–535.6] | 103.1 [88.6–126.8] |
| the open step | 104.1 [58.2–541.0] | 68.8 [42.9–192.0] | 52.4 [44.8–168.0] | 59.0 [46.3–297.2] |
| define and retry | 218.4 [188.1–478.7] | 306.6 [203.7–584.2] | 246.4 [214.6–407.3] | 246.8 [220.0–357.1] |
| the dropped link whole again | 1236.2 [1159.3–1580.5] | 1203.5 [1134.7–1392.8] | 1249.9 [1136.1–1291.9] | 1229.7 [1160.5–1458.1] |

By name and by address agree within their ranges on every request, as on
the iPhone; the open step by name was slower on the idle rows only (104
against 69 ms at the median, the ranges overlapping). The iPad's stalls
are in both forms: request maxima of 0.1 to 0.58 s, so they are the
link's or the device's, not the name's.

**Round trips over Wi-Fi** (requests per session: p50 of the sessions'
p50s [their range] / max of their maxima, ms; Mac to Mac by LAN address
from the table above for the comparison):

| request | iPhone, idle, LAN | iPhone, ring, LAN | iPhone, idle, Bonjour | iPhone, ring, Bonjour | iPad, idle, LAN | iPad, ring, LAN | Mac to Mac, TCP 192.168.1.10 |
|---|--:|--:|--:|--:|--:|--:|--:|
| `class.definition` | 12: 3.9 [3.5–5.1] / 50.5 | 12: 8.2 [6.9–9.3] / 218.0 | 12: 3.8 [3.4–4.6] / 152.6 | 12: 8.1 [6.8–10.3] / 26.0 | 12: 6.9 [5.4–24.6] / 432.2 | 12: 9.9 [8.5–12.0] / 203.7 | 12: 0.8 [0.8–0.9] / 6.8 |
| `class.hierarchy` | 5: 40.9 [38.7–55.1] / 83.8 | 5: 47.4 [42.9–50.7] / 96.0 | 5: 39.9 [38.9–48.1] / 185.4 | 5: 49.0 [44.6–60.6] / 75.4 | 5: 64.9 [41.9–479.6] / 704.2 | 5: 51.7 [42.3–88.6] / 313.3 | 5: 29.0 [26.1–30.8] / 31.6 |
| `class.hierarchy (retried)` | 1: 1151.4 [1118.3–1226.6] / 1226.6 | 1: 1176.6 [1069.3–1261.1] / 1261.1 | 1: 1185.2 [1091.4–1210.0] / 1210.0 | 1: 1160.7 [1126.6–1226.4] / 1226.4 | 1: 1175.4 [1110.6–1319.2] / 1319.2 | 1: 1162.3 [1103.7–1373.5] / 1373.5 | 1: 1049.8 [1033.4–1050.2] / 1050.2 |
| `class.selectors` | 14: 4.6 [3.5–5.3] / 74.5 | 14: 8.0 [6.7–9.3] / 72.5 | 14: 4.3 [3.4–5.4] / 151.2 | 14: 7.6 [6.6–8.4] / 78.3 | 14: 7.0 [6.0–15.8] / 428.0 | 14: 10.1 [8.6–11.8] / 203.3 | 14: 1.1 [1.0–1.6] / 57.6 |
| `evaluate` | 3: 3.4 [3.0–7.3] / 26.1 | 3: 12.2 [7.6–22.4] / 40.1 | 3: 5.5 [3.1–14.3] / 37.2 | 3: 9.5 [6.9–18.6] / 26.1 | 3: 7.3 [6.0–25.6] / 88.0 | 3: 12.2 [9.8–26.3] / 104.8 | 3: 4.5 [0.7–4.6] / 8.7 |
| `method.compile` | 4: 6.9 [5.1–9.4] / 51.8 | 4: 11.9 [8.8–18.4] / 59.1 | 4: 7.0 [5.9–8.2] / 152.9 | 4: 13.0 [9.7–23.3] / 43.2 | 4: 8.6 [6.1–14.7] / 298.2 | 4: 15.1 [10.1–22.7] / 206.3 | 4: 3.6 [3.5–5.4] / 6.7 |
| `method.remove` | 1: 6.4 [3.3–15.4] / 15.4 | 1: 11.5 [4.1–15.6] / 15.6 | 1: 6.7 [3.3–26.1] / 26.1 | 1: 12.7 [5.5–37.8] / 37.8 | 1: 11.9 [4.5–232.1] / 232.1 | 1: 15.7 [5.3–99.7] / 99.7 | 1: 3.0 [3.0–3.1] / 3.1 |
| `method.source` | 10: 5.4 [3.1–6.4] / 25.3 | 10: 6.9 [5.8–8.5] / 33.7 | 10: 5.0 [3.2–6.3] / 24.8 | 10: 6.7 [6.2–8.0] / 26.1 | 10: 7.1 [5.9–8.2] / 297.0 | 10: 9.0 [7.7–10.5] / 294.8 | 7: 0.6 [0.6–0.7] / 14.7 |
| `package.list` | 4: 4.7 [4.0–14.6] / 71.7 | 4: 7.5 [5.5–13.2] / 75.1 | 4: 4.4 [3.7–13.2] / 175.8 | 4: 9.0 [5.1–15.6] / 26.8 | 4: 7.2 [5.4–98.0] / 630.8 | 4: 9.7 [7.4–16.4] / 210.0 | 4: 2.0 [1.0–2.1] / 11.4 |
| `package.selectors` | 2: 77.2 [76.5–85.1] / 94.6 | 2: 95.6 [91.9–105.0] / 124.8 | 2: 77.4 [76.7–92.1] / 95.1 | 2: 103.0 [91.2–111.9] / 118.4 | 2: 96.9 [82.7–467.7] / 482.7 | 2: 103.2 [91.1–127.2] / 357.2 | 2: 78.1 [75.2–78.1] / 82.6 |
| `process.frames` | 6: 78.2 [63.9–93.5] / 122.4 | 6: 78.5 [45.1–94.2] / 119.4 | 6: 71.5 [37.9–95.1] / 121.2 | 6: 73.5 [49.5–83.9] / 221.3 | 6: 65.7 [56.6–76.8] / 247.8 | 6: 62.1 [57.4–74.9] / 325.0 | 6: 42.1 [28.9–51.1] / 88.6 |
| `process.list` | 1: 8.7 [4.4–23.4] / 23.4 | 1: 13.3 [8.0–19.5] / 19.5 | 1: 6.2 [4.6–18.5] / 18.5 | 1: 13.4 [10.3–34.2] / 34.2 | 1: 11.8 [8.1–19.2] / 19.2 | 1: 15.4 [10.6–96.2] / 96.2 | 1: 1.8 [1.0–2.0] / 2.0 |
| `process.list (retried)` | 1: 1086.8 [1030.3–1146.5] / 1146.5 | 1: 1104.3 [1032.7–1177.7] / 1177.7 | 1: 1104.2 [1050.5–1155.1] / 1155.1 | 1: 1104.6 [1057.6–1157.9] / 1157.9 | 1: 1058.9 [1026.2–1234.1] / 1234.1 | 1: 1095.3 [1024.4–1291.1] / 1291.1 | 1: 1006.5 [1006.4–1008.6] / 1008.6 |
| `process.restart` | 1: 3.1 [2.7–4.8] / 4.8 | 1: 7.4 [5.0–10.2] / 10.2 | 1: 3.1 [2.7–24.9] / 24.9 | 1: 6.6 [3.8–24.8] / 24.8 | 1: 5.7 [3.4–7.7] / 7.7 | 1: 9.0 [4.9–23.1] / 23.1 | 1: 0.6 [0.5–0.6] / 0.6 |
| `process.retrySend` | 1: 26.4 [3.2–35.9] / 35.9 | 1: 31.0 [12.3–47.4] / 47.4 | 1: 28.2 [3.1–44.4] / 44.4 | 1: 29.3 [7.0–44.1] / 44.1 | 1: 23.6 [4.5–39.7] / 39.7 | 1: 34.8 [29.2–216.0] / 216.0 | 1: 20.0 [20.0–25.1] / 25.1 |
| `process.step` | 2: 5.1 [3.2–9.7] / 27.2 | 2: 7.0 [5.5–8.3] / 17.8 | 2: 5.4 [3.1–6.4] / 13.8 | 2: 7.1 [6.3–9.1] / 30.0 | 2: 6.7 [3.4–11.3] / 351.5 | 2: 9.5 [6.3–12.6] / 83.9 | 2: 2.0 [0.5–4.2] / 5.7 |
| `process.terminate` | 1: 9.1 [3.6–24.3] / 24.3 | 1: 10.4 [6.7–21.8] / 21.8 | 1: 6.2 [3.5–25.9] / 25.9 | 1: 10.8 [6.7–27.8] / 27.8 | 1: 14.4 [11.6–159.7] / 159.7 | 1: 9.8 [5.8–14.7] / 14.7 | 1: 5.4 [0.6–8.5] / 8.5 |
| `test.run` | 1: 32.2 [23.8–59.0] / 59.0 | 1: 33.3 [19.9–61.2] / 61.2 | 1: 32.2 [14.3–48.0] / 48.0 | 1: 48.2 [17.8–72.0] / 72.0 | 1: 74.6 [16.0–464.1] / 464.1 | 1: 25.0 [15.0–285.6] / 285.6 | 1: 40.0 [7.6–42.9] / 42.9 |

- **Wi-Fi adds a few milliseconds to a small request**: the iPhone
  answers `class.definition`, `class.selectors`, `method.source` and
  `package.list` in 3.8 to 5.4 ms at p50 with the target idle (the Mac to
  itself 0.6 to 2.0), 6.7 to 9.0 with the ring running on the phone; the
  iPad 6.9 to 7.2 and 9.0 to 10.1. The Bonjour name costs nothing after
  the first connect (the iPhone's rows by name and by address agree
  within the ranges; the open step is 52 to 60 ms by name against 49 to
  56 by address, where the Mac's own name cost 0.28 to 0.44 s).
- **The large replies are the device's work**: `class.hierarchy` (176
  classes, 16.5 KB) 40 to 41 ms on the idle iPhone, 47 to 49 under the
  ring, 52 to 65 on the iPad, against 29 Mac to Mac; `package.selectors`
  of Kernel (2043 methods, about 57 KB) 77 ms idle and 96 to 103 under
  the ring on the iPhone, 97 to 103 on the iPad, against 78. On the idle
  iPhone the hierarchy costs 11 to 12 ms more than on the Mac and the
  selectors nothing more.
- **The iPad's link stalls**: its maxima reach 0.2 to 0.7 s on requests
  whose p50 is under 10 ms (`class.definition` 432 ms, `package.list`
  631, `class.hierarchy` 704, the first session's open step 706), in
  runs scattered over both scenarios, with the iPad's own turns at 3.4 to
  6.5 ms; the iPhone's maxima stay under 0.25 s. The Wi-Fi of a
  2018 iPad (or its power saving between bursts) is the suspect, not
  measured further.
- Retried requests count from their first send as on the Mac: the 1 s
  backoff, then 0.05 to 0.2 s more (1.06 to 1.19 s at p50 against the
  Mac's 1.007 to 1.050).

**Sessions and the dropped link** (the client shell's frames missed in the
session; outage from the loss to the new session):

| target | sessions | seconds | client frames missed | reconnects | outage ms | sent again |
|---|--:|--:|--:|--:|--:|--:|
| iPhone, idle, LAN | 14 | 2.8 [2.7–2.9] | 68 [60–74] | 1 | 1079.7 [1024.3–1140.2] | 2 |
| iPhone, ring, LAN | 12 | 3.1 [3.0–3.3] | 66 [61–73] | 1 | 1093.1 [1024.8–1167.0] | 2 |
| iPhone, idle, Bonjour | 13 | 2.9 [2.8–3.0] | 69 [59–78] | 1 | 1093.5 [1046.1–1136.9] | 2 |
| iPhone, ring, Bonjour | 12 | 3.0 [2.9–3.2] | 65.5 [55–84] | 1 | 1093.0 [1048.0–1138.7] | 2 |
| iPad, idle, LAN | 11 | 3.4 [3.0–6.9] | 46 [40–72] | 1 | 1051.6 [1019.3–1224.6] | 2 |
| iPad, ring, LAN | 12 | 3.3 [3.1–4.0] | 45 [35–63] | 1 | 1063.6 [1014.8–1281.0] | 2 |
| Mac to Mac, TCP LAN, target idle | 18 | 2.33 [2.24–2.38] | 46 [41–51] | 1 | 1007.0 [1004.5–1009.0] | 2 |
| Mac to Mac, TCP LAN, target ring | 18 | 2.42 [2.37–2.46] | 52 [46–57] | 1 | 1006.2 [1003.7–1008.1] | 2 |

Steps (ms):

| step | iPhone, idle, LAN | iPhone, ring, LAN | iPhone, idle, Bonjour | iPhone, ring, Bonjour | iPad, idle, LAN | iPad, ring, LAN | Mac to Mac, TCP 192.168.1.10 |
|---|--:|--:|--:|--:|--:|--:|--:|
| open | 56.4 [47.5–73.6] | 48.9 [47.6–96.7] | 60.2 [42.0–139.6] | 52.4 [46.6–56.9] | 133.9 [59.9–705.8] | 56.8 [48.0–244.4] | 30.7 [30.6–30.8] |
| reset | 14.1 [11.5–17.8] | 17.4 [10.9–23.8] | 12.0 [11.2–30.8] | 17.9 [11.9–39.7] | 17.6 [11.9–233.4] | 23.9 [12.2–101.5] | 6.5 [5.5–9.2] |
| populate.push | 44.3 [38.2–69.4] | 44.1 [39.0–51.3] | 41.8 [38.1–46.8] | 50.6 [38.2–68.8] | 66.0 [46.8–494.1] | 50.4 [40.7–134.3] | 27.1 [26.7–32.9] |
| populate.onDemand | 41.6 [41.3–41.8] | 45.8 [41.6–58.2] | 41.7 [41.5–53.2] | 49.2 [41.4–74.9] | 64.3 [48.3–100.1] | 53.1 [41.5–59.4] | 25.0 [24.9–33.4] |
| tree.push | 7.0 [6.9–15.4] | 6.9 [6.8–7.2] | 6.9 [1.6–7.0] | 6.9 [6.8–7.0] | 7.1 [1.6–8.5] | 6.7 [1.5–7.2] | 6.8 [6.7–6.9] |
| tree.onDemand | 1.3 [1.3–1.4] | 1.3 [1.3–6.9] | 1.3 [1.3–7.2] | 1.3 [1.3–1.5] | 7.3 [1.6–8.3] | 1.3 [1.2–7.3] | 1.4 [1.3–1.5] |
| selectors.request | 87.9 [79.7–94.7] | 97.0 [94.3–105.1] | 91.3 [83.8–95.2] | 104.0 [95.0–112.6] | 121.5 [93.8–467.8] | 110.8 [93.1–205.3] | 78.1 [75.3–78.2] |
| selectors.push.2043 | 6.5 [1.4–14.2] | 6.5 [6.4–8.6] | 8.4 [1.2–14.2] | 8.5 [6.4–9.0] | 1.4 [1.0–10.6] | 4.9 [1.0–14.6] | 1.7 [1.7–7.0] (2049) |
| selectors.onDemand.2043 | 9.6 [9.0–14.0] | 9.6 [9.1–10.1] | 9.6 [9.0–12.3] | 9.4 [9.0–9.9] | 10.0 [9.3–15.5] | 13.4 [9.0–21.0] | 11.1 [9.8–11.2] (2049) |
| select.10 | 202.9 [183.6–219.0] | 262.7 [222.1–296.9] | 203.6 [182.8–228.5] | 250.8 [189.8–311.3] | 419.2 [263.9–1431.7] | 398.3 [275.3–778.4] | 156.8 [139.0–156.9] |
| compile | 16.6 [14.1–40.1] | 28.6 [24.3–240.8] | 15.0 [13.1–30.4] | 35.0 [24.6–52.8] | 30.4 [19.3–41.7] | 35.5 [24.1–135.7] | 17.1 [15.2–17.5] |
| test.run | 60.7 [39.0–74.4] | 50.6 [31.0–75.1] | 60.6 [52.9–70.3] | 62.8 [31.2–89.9] | 100.0 [16.5–507.6] | 48.3 [23.8–288.9] | 43.9 [32.0–48.1] |
| error.debugger | 105.2 [92.0–140.4] | 122.1 [94.9–148.9] | 106.6 [80.8–132.0] | 109.2 [89.3–141.6] | 107.6 [73.9–135.7] | 100.4 [74.9–198.9] | 83.7 [74.9–98.3] |
| step | 34.4 [26.7–57.4] | 52.6 [46.6–70.7] | 35.4 [26.9–50.0] | 66.3 [52.0–73.5] | 59.9 [34.7–418.7] | 66.2 [51.4–267.2] | 25.7 [21.9–26.0] |
| fix.proceed | 14.4 [12.4–32.7] | 25.8 [19.2–38.2] | 14.4 [12.4–36.7] | 31.0 [17.9–50.4] | 25.1 [12.1–306.6] | 29.9 [17.9–42.9] | 12.1 [11.7–12.7] |
| define.retry | 280.8 [252.4–341.1] | 296.9 [266.6–422.5] | 295.1 [260.0–406.8] | 299.4 [239.1–345.1] | 234.5 [198.7–419.4] | 314.7 [214.2–427.3] | 210.9 [202.5–224.7] |
| drop.stop | 108.3 [98.1–124.0] | 114.2 [99.7–150.4] | 113.5 [91.2–143.6] | 114.1 [97.3–241.9] | 91.2 [69.1–184.8] | 92.9 [72.5–172.2] | 82.7 [62.3–99.5] |
| drop.reconnect | 1182.3 [1144.0–1251.4] | 1196.8 [1080.0–1292.1] | 1202.5 [1100.5–1249.8] | 1195.8 [1151.4–1251.5] | 1199.1 [1126.9–1343.9] | 1212.2 [1129.5–1392.4] | 1060.8 [1042.3–1068.4] |
| drop.terminate | 14.8 [5.8–28.5] | 16.3 [11.4–24.9] | 12.2 [5.8–30.4] | 16.5 [10.9–34.0] | 18.8 [15.0–170.6] | 15.4 [6.8–30.9] | 8.5 [6.3–14.4] |

- **The debugger across Wi-Fi** (`define.retry`): 0.23 to 0.31 s at p50
  from the doit to the Process going on after the method was defined from
  the Mac's debugger and the send retried (the Mac to itself 0.20 to
  0.21); the doit's stop with the debugger open (`drop.stop`) 0.09 to 0.11
  s.
- **The dropped link**: everything back (both replies, the stopped Process
  listed as stopped, its debugger's frames fetched again) 1.18 to 1.21 s
  after the drop at p50 on both devices (Mac to Mac 1.05 to 1.09), of
  which 1.006 s is the backoff; the reconnect itself (the outage) 1.05 to
  1.09 s. Two requests were pending at every loss and both were sent
  again and answered.
- `select.10` (ten classes selected, each a definition and its selectors)
  is the step that shows the link most: 0.20 s idle and 0.25 to 0.26 s
  under the ring on the iPhone, 0.40 to 0.42 s on the iPad, 0.16 Mac to
  Mac.
- The client shell missed more frames per session against the iPhone (55
  to 84) than against the Mac or the iPad (35 to 72): the sessions are
  longer and the windows and debugger open in them as before; the
  client's misses are AppKit's, not the link's (9c's and the Mac-to-Mac
  finding), and were not separated further.

**The serving device's frames** (20 s windows at 120 Hz; with a client,
the four or five sessions above in the window; the control row with
none; 9a's rows and the Mac to Mac rows for the comparison):

| row | runs | missed of 2400 | longest turn ms | requests served | main thread CPU ms per 10 s | stopped for others ms per 10 s | `deliver` max µs | power W | peak MB | thermal at start |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| iPhone, idle, a client (LAN) | 3 | 0 | 3.3 | 350 [280–350] | 3639 [3624–3639] | 0.3 [0.1–0.5] | 36.1 [25.5–149.9] | 0.34 [0.28–0.36] | 74 [69–74] | nominal, fair, serious |
| iPhone, idle, a client (Bonjour) | 3 | 0 | 3.3 | 280 [280–350] | 3652 [3645–3654] | 0.4 [0.3–0.5] | 39.5 [34.8–41.6] | 0.30 [0.29–0.33] | 70 [69–73] | nominal, nominal, serious |
| iPhone, idle, no client | 3 | 0 | 3.3 | 0 | 3696 [3617–3697] | 0 | - | 0.019 [0.016–0.084] | 33 [33–34] | nominal, fair, fair |
| iPhone, ring, a client (LAN) | 3 | 0 | 5.0 [4.8–5.3] | 280 | 2946 [2802–3005] | 52.9 [45.7–53.7] | 230.9 [142.0–581.2] | 3.5 [3.4–3.8] | 583 [580–591] | nominal |
| iPhone, ring, a client (Bonjour) | 3 | 0 | 5.2 [4.6–6.3] | 280 | 3056 [2902–3607] | 54.1 [48.4–70.8] | 73.6 [66.0–90.2] | 3.3 [2.1–3.5] | 585 [564–586] | nominal, fair, fair |
| iPhone, ring, no client | 3 | 0 | 4.7 [4.6–5.0] | 0 | 2727 [2570–2774] | 50.1 [44.3–59.6] | - | 4.0 [3.9–4.4] | 593 [581–596] | nominal |
| iPad, idle, a client (LAN) | 3 | 0 | 3.5 [3.4–3.5] | 278 [210–280] | 3647 [3641–3647] | 0.4 [0.3–0.8] | 84.1 [81.8–273.4] | 0.05 | 59 [55–60] | nominal, nominal, fair |
| iPad, idle, no client | 3 | 0 | 3.4 [3.3–3.6] | 0 | 3622 [3620–3627] | 0 | - | 0.025 | 27 | nominal, nominal, fair |
| iPad, ring, a client (LAN) | 3 | 0 | 6.5 [6.4–6.5] | 276 [276–278] | 3426 [3406–3447] | 101.3 [89.0–107.1] | 68.0 [56.8–139.8] | 1.25 [1.22–1.25] | 569 [525–571] | nominal, nominal, fair |
| iPad, ring, no client | 3 | 0 | 6.5 [6.3–7.3] | 0 | 3376 [3374–3377] | 101.5 [94.2–105.7] | - | 1.25 [1.24–1.26] | 531 [520–560] | nominal, nominal, fair |
| 9a's rows (10 s), iPhone idle / ring offload (serious) | 3 | 0 / 0 of 1200 | - | - | - | 0.0 / 80.5 | - | 0.016 / 1.8 | 31 / 557 | serious |
| 9a's rows (10 s), iPad idle / ring offload | 3 | 0 / 0 of 1200 | 3.6 to 3.8 / 6.9 to 7.2 | - | - | 0.0 / 92.6 | - | 0.017 / 1.1 | 27 / 544 | nominal, fair |
| Mac to Mac: idle / ring, a client | 3 | 0 / 0 | 3.2 / 3.7 | 374 / 385 | 2704 / 2064 | - | 29.1 / 35.0 | - | - | fair |

- **No frame missed on either device while serving a client**, idle or
  under the ring, by address or by name; the longest main-thread turn
  stayed the scenario's (3.3 to 3.5 ms idle, 5.0 to 6.5 under the ring),
  the same with and without a client. The requests run on the background
  workers and the few that touch views hop to main inside the budget,
  as on the Mac.
- **A client costs the main thread nothing it measures**: the stopped
  time with a client equals the control row's (iPhone ring 53 to 54
  against 50 ms per 10 s, iPad 101 against 102), and so does the main
  thread's CPU idle (3.6 to 3.7 s per 10 s either way). Under the ring
  with a client the iPhone's main thread used 0.2 to 0.3 s more per 10 s.
- **A client is not free in energy**: on the idle iPhone the process drew
  0.30 to 0.34 W with a client against 0.019 W without (the requests'
  Processes on the workers, the socket and the Wi-Fi wakeups the reading
  attributes to the process), and peaked at 70 to 74 MB against 33; the
  iPad's 0.05 against 0.025 W (its readings low throughout, shells.md).
- `deliver` stayed in microseconds (at most 0.58 ms, once, on the iPhone
  under the ring); at most 55.4 KB waited in a writing queue, the Kernel
  selectors' reply as on the Mac.
- Thermal: the iPhone's rows started at nominal, fair or serious (it had
  served the probe launch just before and was not cooled between rows); the iPad's at nominal, fair in the third
  run. Per row in the table; per launch in `serve-*.txt`.

**The kernel tests**: the iPad Pro passed 202 of 202 (7083 ms, nominal,
peak 59 MB; shells.md). The iPhone's 202 of 202 since 815b512 is the
follow-up's.

**The question 9d left for the devices** (whether the class tree wants
the on-demand form or a request per package over Wi-Fi): **neither; push
stays the default**. Over Wi-Fi the tree's reply cost the idle iPhone 11
to 12 ms more than the Mac to itself for 176 classes (40 against 29 ms),
the iPad 23 to 36 ms more; scaled by bytes to 9c's 2009 classes that is
about 0.13 to 0.4 s beside the 0.33 s the client spends reading the
reply in any case, and the client-side steps (`tree.push` 7 ms,
`tree.onDemand` 1.3 ms) are what they were Mac to Mac. The 2000-class
image itself was not served from a device; if it is, the first number
to read is `class.hierarchy` against the 0.33 s local.

**The partial run of 00:17** (before Local Network was allowed and the
iPad was signed) is kept below as it was recorded.

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

(At 00:31 the question 9d left for the phone was still open: no request
had crossed Wi-Fi. It is answered above.)

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

- **The iPad's Bonjour rows** were not done in the morning's run and are
  done since (2026-11-06 11:44, "On the devices"): the cause was iPadOS's
  local network permission for Kajo, which the owner granted. Set only
  `DEVICE=00008027-0012592C0185002E` for `scripts/remote-session.sh
  device`; `DD` is read by `scripts/mac-shell.sh` too and moves the Mac
  client's path.
- **The 2000-class image served from a device.** The rows used the
  shell image (176 classes); the class tree's cost over Wi-Fi for 2009
  classes is an extrapolation ("On the devices").
- **The iPad's link stalls** (request maxima of 0.2 to 0.7 s over p50s
  under 10 ms) are not explained; the iPhone's maxima stayed under 0.25 s.
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
   *2026-11-06, later*: both done; the rows ran on the iPhone and the iPad
   the same morning (51 and 23 sessions, no failure, no frame missed on
   either device). One owner step remains: the iPad's local network
   permission for Kajo, if it is asking, so its Bonjour name appears.
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
   act of a development image. (Superseded for generated apps by the
   owner's distribution shape of 2026-11-05: a Debug build serves from
   launch, module 11a; the shells keep the argument.)
5. **Signing**: the owner clears the keychain prompt on the mini, then the
   phone's rows run with `scripts/device.sh build` and
   `scripts/remote-session.sh device`.
6. **The not-retried requests**: fail them, as built. A resend cannot tell
   a doit that never arrived from one whose reply was lost, so it guesses
   wrong exactly when the doit had side effects. If doits are ever
   retried, the form is a request id the target remembers and answers
   from, a protocol change, not a flag.

### The owner's answers after the device run (2026-11-06)

The run on the devices ("On the devices") left three things to decide:

1. **The fallbacks under large churn on the devices**: if such churn is
   likely in real use (a photo or video app), tune it for devices. It is
   plausible, so the large-objects follow-up tunes the trigger
   (`docs/modules/large-objects.md`, the owner's answers).
2. **The iPad's three unexplained readings** (event latency under the
   storm, request maxima over Wi-Fi, energy): the owner suspects the
   iPad's battery at least for the energy, and an investigation is to be
   run.
3. **The 2000-class image served from a device**, to check that the class
   tree keeps the push form: yes, run it.

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
- **The phone's measurements** (2026-11-06): the round trips over Wi-Fi
  answered that the class tree keeps the push form ("On the devices");
  the 2000-class image served from a device is the measurement that
  would revisit it.

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
| section 3 on the devices, 2026-11-06 07:16 to 07:45 (d70cda2's build; the iPad's lan rows after 7bdb024's script fix) | iPhone: 18 serving launches, 51 sessions by address and name, no failure, 0 frames missed; iPad: 12 serving launches, 23 sessions by address, no failure, 0 frames missed, its Bonjour name never seen ("On the devices") |
| the iPad's Bonjour rows, 2026-11-06 11:44 to 11:51 (the same builds, after the owner granted the iPad's local network permission) | 12 serving launches, 45 sessions (22 by name, 23 by address), no failure, 0 frames missed ("On the devices") |
| `just ios-check` and `just apps` after 7bdb024's script change (2026-11-06 07:49 to 07:51) | exit 0, 0 errors, 0 warnings, both |
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
