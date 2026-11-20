# The third review (2026-11-20): hosts

Area: the Swift outside the VM core. Read at 821f20f. No build, no test, no
launch was made; every number below is from a file that already existed
(named where it is used) or is written as the measurement to make.

## The findings, in the order I would do them

| # | id | one line | expected gain |
|--:|---|---|---|
| 1 | hosts.M1 | Seven transcript sinks parse every kernel line with `JSONSerialization`, protocol replies included, on the emitting VM thread inside the VM | a whole-reply parse and a copy gone per reply and per event (milliseconds per megabyte, inside the VM); seven copies become one |
| 2 | hosts.M2 | The image is read, loaded and bound on the main thread after the host is ready, while the system's own launch runs for 120 ms before it | up to 40 ms of a 230 to 250 ms cold launch (the Mac Release sample's own trace) |
| 3 | hosts.M6 | UIKit's `appendLine` reads and sets the whole text for every line | a Transcript on iOS goes from O(text) to O(line) per line |
| 4 | hosts.R1 | KajoDev has three line readers, three write loops and three "close the descriptor once" rules | one place for the rule three review fixes had to repair one by one; the seam for M3 and M5 |
| 5 | hosts.A1 | `Headless.swift` builds every collector's report: 349 hand-typed names, seven percentile closures with two rules, enum names by index tables, two definitions of the main thread's "own" time | a new counter is one module wide; one percentile rule; no index table that can trap after a run |
| 6 | hosts.A2 | VM options are parsed in three places with two spellings; a bad value or an unknown key falls to the default silently | an A/B row cannot measure the default twice without saying so |
| 7 | hosts.M3 | One reply crosses the two hosts in about seven copies and three full parses in Swift | bound it first; then two to four copies and two parses less per reply |
| 8 | hosts.R2 | `AppKitHost` and `UIKitHost` repeat the dispatch, the argument checks, the colour names and the style parsing; they already differ | the next UIKit view kind is a leaf; one protocol behaves the same on both |
| 9 | hosts.M4 | Image timers run on `DispatchQueue.global()` | timer lateness independent of process load; the gate-speed record's open item (two kernel parts against five) |
| 10 | hosts.M5 | Every line written costs a hop to a per-connection queue; the transport's threads have no QoS decided | two of six thread wakeups less per round trip |
| 11 | hosts.A3 | Every Release app links the kasm assembler, `Headless.run`, the fuzz entries and the compiler probe; `kajo-bench=` is the only user and no script runs it | a smaller trusted binary; "not in the release build" checked for the tools too |
| 12 | hosts.R3 | `ShellBridge` holds the same queue twice (events, requests) | one generic queue; a fix like item 16 is made once, not four times |
| 13 | hosts.R4 | "Run this main Process to its end" is written seven times, as a spin on the main thread | one helper that waits instead of spinning |
| 14 | hosts.A4 | The bootstrap compiler parses the type grammar into trees and speaks five private record formats to the kernel | type syntax changes in one language; the image build hands over files, not records |

Counts: 6 mechanical, 4 architecture, 4 reuse. Smaller items and the bugs
met on the way are at the end.

---

## hosts.M1: every kernel line is parsed whole by a transcript sink

**Where.** The sinks: `Sources/KajoApp/Application.swift:202`,
`Sources/KajoShellCore/App.swift:80`, `Scenario.swift:246`,
`DevModes.swift:105` and `:283`, `Sources/kajo/main.swift:184` and `:373`.
The path to them: `Sources/KajoVM/ObjectModel/KernelPrimitives.swift:86`
(primitive 140), `Sources/KajoVM/Shell/ShellPrimitives.swift:156`
(primitive 161), `ShellBridge.swift:252`, `Sources/KajoApp/ShellRuntime.swift:24`,
`Sources/KajoDev/Target.swift:51`.

**What is there now.** Every line the kernel emits, an event of primitive
140 or a protocol reply of primitive 161, goes to the host's `events`
callback. Each host's callback is one of seven copies of

```swift
guard let o = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
      o["kind"] as? String == "transcript", let t = o["text"] as? String else { return }
```

`RuntimeLink.emit` calls it first and the serving tap second, so in a
Debug app, in the shells' developer modes and in `kajo run --protocol`
every reply is copied into a `Data` and parsed into Foundation objects
only to learn that its kind is not `transcript`.

**The cost.** Per reply and per event: one copy of the line and one full
parse that builds an `NSDictionary` tree, on the VM thread that emitted
it. The call is made inside the VM with no blocking region (both
primitives call the hook directly), so the worker does not poll while
Foundation parses, and a stop requested meanwhile waits for it. The
replies that matter are the large ones: `class.hierarchy` of 2009
classes and `package.selectors` of 19 866 methods
(`docs/modules/developer-ui.md`, the request table). The time is not
measured anywhere: `ServerStats.deliverTotalNs` starts after the sink.

**The proposal.** One function in `KajoVM/Shell` (a Release app needs it,
so not in KajoDev), `transcriptText(ofLine:) -> String?`. It compares the
line's first bytes with `{"v":1,"kind":"transcript"` and parses only a
line that matches. The prefix is the writer's own:
`KernelPrimitives.swift:66` starts every event with `{"v":1,"kind":`, and
`ProtocolServer.deliver` (`Server.swift:514`) and `Test.swift:67` already
route by such a prefix. The seven sinks become one call each.

**Bound and measure.** Before: a clock read around the hook call in
`shellEventHook` and in primitive 161, summed as two counters (lines,
bytes, ns, longest) and printed on the `devsession` and `scenario` result
lines. Read them on `mode=devsession classes=2000` (the row with
`class.hierarchy` and `package.selectors`). After: the same row; the
counter should fall to the cost of the prefix compare. Also read
`stopsByKind`'s time to safepoint in `devsession load=storm`.

**Risk and size.** Small. The trust boundary does not move: the sink only
prints the Transcript. A test: a reply line whose text holds
`"kind":"transcript"` further in is not printed. Swift tier
(`Shell/` is not a core directory).

**Confidence.** Read, for the path and the seven copies. The time per
megabyte is a guess until the counter exists.

---

## hosts.M2: the image is opened on the main thread after the host is ready

**Where.** `Sources/KajoApp/Application.swift:306` (`main`), `:330`
(`launch`), `:92` (`start`); `Sources/KajoApp/ShellRuntime.swift:58`;
`Sources/KajoVM/Shell/Shell.swift:374`.

**What is there now.** `KajoApplication.main` stores the configuration and
enters `NSApplication.run` or `UIApplicationMain`. The host is made in
`applicationDidFinishLaunching` or `viewDidAppear`; `launch` then queues
`start` on the main queue, and `start` reads the image file, loads it,
binds the native module and runs `open`:

```swift
guard let data = FileManager.default.contents(atPath: path) else { throw .image("cannot read \(path)") }
try self.init(image: [UInt8](data), options: options, callbacks: callbacks)
```

The file is read into a `Data`, copied into an Array, and copied again
by the loader.

**The cost.** The Mac Release sample's five launches
(`~/kajo-scratch/native-by-default/part3/roundtrip/console-release-launch-{1..5}.log`):
`host-ready` at 120.5 to 192.7 ms in launches 2 to 5 (321 in the first
after the build), `image-opened` 39.6 to 41.5 ms later in every launch (of
it `bind_ms` 5.4), `app-opened` 44 to 55 ms after that, first frame at
229 to 311 ms (451 in the first). The image is 6.6 MB. So 40 ms of
main-thread work sits after a stretch of 120 ms or more in which the main
thread is inside the system's launch and the other cores have nothing of
Kajo's to do.

**The proposal.** Start the open at the top of `KajoApplication.main`, on
a thread of its own at user-interactive QoS: read the image, `ShellVM`
init, the native bind. `launch(on:)` takes the opened VM (it waits for it
if it is not ready, which is today's time at worst) and builds the
`ShellRuntime` around it. `RuntimeLink` is already built outside the main
actor, and its `runtime` is weak and nil until attached, so a wake before
the attach does nothing; the `open` loop turns at once after the attach.
`ShellRuntime` gets an initializer that takes a `ShellVM`. Second, smaller
part: map the file and give the loader a buffer, so the two extra copies
of 6.6 MB go.

**Bound and measure.** The ceiling is already printed: `image-opened`
minus `host-ready` in the launch trace. After: `first_frame_ms` and the
steps, five launches Debug and Release on the Mac and the iPhone, both
orders, thermal state on each line (`app-roundtrip.sh mac|device`).

**Risk and size.** Small to medium. What to check first: that nothing in
`VM.init` binds to the creating thread. I found none: the VM's threads
record themselves when they run (`Workers/Run.swift:114`), and
`Collect.swift:252` asks `pthread_main_np` at each collection. The closed
shell's rule (close from the thread that drives the VM,
`docs/modules/closed-shell-calls.md`) is untouched: the opener thread ends
before the first turn. A failed open must still reach `showStatus` on the
main thread. Tests: `ShellTests`, `DistributionTests`; gates: Swift tier,
`just new-check`.

**Confidence.** Read for the launch path and the trace; inferred for
`VM.init`'s thread independence (I did not read it whole).

---

## hosts.M6: UIKit's `appendLine` is O(text) per line

**Where.** `Sources/KajoApp/UIKitHost.swift:249`. The Mac's second-round
path for comparison: `Sources/KajoApp/AppKitViews.swift:557`.

**What is there now.**

```swift
t.text = (t.text ?? "").isEmpty ? line : t.text + "\n" + line
t.scrollRangeToVisible(NSRange(location: (t.text as NSString).length, length: 0))
```

Each line reads the whole text (a bridged copy), builds a new String,
sets it (UIKit lays the whole text out again) and reads it once more for
its length. The Mac appends to `textStorage`.

**The cost.** Per appended line: three passes over the whole text and a
full layout, on the main thread inside a view call. A Transcript of n
lines costs O(n squared). On the phone this is the view an app's log or
the tools' Transcript would use.

**The proposal.** Append to `t.textStorage` as the Mac does and scroll to
`t.textStorage.length`. With hosts.R2 it is one function in the shared
core.

**Bound and measure.** `onViewDone` already times every view call
(`DevModes.swift:218`). On the iPhone: 1000 `appendLine` calls in
`mode=demo`, the op's total and longest, before and after.

**Risk and size.** Small. `ViewWrapperTest` and the iPhone's tests mode
cover the op. Swift tier; one device run for the number.

**Confidence.** Read.

---

## hosts.R1: three line readers, three writers, three close-once rules

**Where.** Readers: `Sources/KajoDev/Server.swift:306` (`readLoop`),
`ClientHost.swift:676` (`readLines`), `Client.swift:82` (`readLoop`).
Write loops: `Server.swift:677`, `ClientHost.swift:662`, `Client.swift:205`
(a fourth, for the token file, `Sources/KajoAppDevelopment/Serving.swift:117`).
Descriptor lifetime: `Server.swift:599` (`Connection`),
`ClientHost.swift:579` (`ClientConnection`), `Client.swift:131` and `:255`.

**What is there now.** Each of the three classes owns a socket and writes
the same three things again: a 64 KiB chunk loop that splits on byte 10
and discards a line past a limit; `var bytes = line; bytes.append(10)` and
a write loop that retries on `EINTR`; and the rule that the descriptor is
shut down under a lock, drained, and closed exactly once by whoever ends
second. The three readers already differ: the server checks the limit
after appending (`Server.swift:357`), the CLI's client before
(`Client.swift:101`), and only the server has the unpaired bounds.

**The cost.** The rule was repaired three times, once per copy: the review
fixes' item 5 (`Connection`), part 2's item 18 (`ClientConnection`) and
item 13 (`ProtocolClient`), each with its own test. The next change to
framing, to the limit, or to how a line is written (hosts.M3's `writev`,
hosts.M5's inline write) has to be made in three places and tested three
times.

**The proposal.** One `LineStream` in `Transport.swift`: it owns the
descriptor; `read(limit:each:)`; `send(_:)` in order; `close()` and the
reader's last step with the close-once rule and the `lateWrites` counter.
`Connection`, `ClientConnection` and `ProtocolClient` keep what is theirs
(the session state, the held lines before `session.open`, the reply
table) and hold a `LineStream`.

**Bound and measure.** No speed claim. The measure is the tests: the three
existing lifetime tests (`ReviewFixesTransportTests`) run against the one
type, and `lateWrites` and `descriptorCloses` stay 0 and 1.

**Risk and size.** Medium. The invariant is "a descriptor is closed once,
never under a read or a write"; AGENTS.md's lesson "A descriptor closed
twice closes someone else's". Swift tier, the protocol fuzzer for 120 s,
ThreadSanitizer under load once (a new suite's own faults).

**Confidence.** Read.

---

## hosts.A1: every collector's report lives in `Headless.swift`

**Where.** `Sources/KajoVM/Headless.swift:401` to `:450` (the run's
counters), `:522` (`nurseryReport`), `:568` (`markingReport`), `:655`,
`:679`, `:720`, `:765`, `:791`, `:806`, `:829`, `:858`
(`relocationReport`), `:897` (`MainLoad`), `:1013` (`youngReport`),
`:1083`. Its second user: `Sources/KajoVM/Shell/Shell.swift:715`. The
shells' line: `Sources/KajoShellCore/Scenario.swift:402` to `:533`. The
readers: `scripts/shell-report.py`, `scripts/golden.sh`.

**What is there now.** One file outside the module directories knows the
fields of every module's counters and logs and writes them as 349
hand-typed `("name", "value")` pairs with 34 `String(format:)` calls.
Three things in it are tables kept by hand that can drift:

1. Percentiles. Seven local closures use `xs[min(n - 1, Int(Double(n) * q))]`
   (`:404`, `:532`, `:577`, `:583`, `:683`, `:769`, `:1023`), and two more
   use `xs[n / 2]` (`:538`, `:540`). The shells use
   `xs[min(n - 1, Int((Double(n - 1) * p).rounded()))]`
   (`Sources/KajoAppDevelopment/Stats.swift:4`, `Sources/KajoApp/Frames.swift:47`).
   On 100 samples the first rule's p99 is the maximum and the second's is
   the 99th value. One scenario row carries both: `gap_p99_ms` and
   `gc_scavP99ms` are different statistics.
2. Enum names by index: `["reserve", "entries", "other", "old", "promotion",
   "verifier", "soft"][Int(r.cause.rawValue)]` (`:833`), and the same shape
   at `:812`, `:813`, `:814`, `:834`, `:835`, `:836`, `:839`, `:691`. They
   match the enums today where I compared them (the five whose enums are
   in `MarkingState.swift`: phase, trigger, requester, justification,
   outcome; not the two cause tables). A
   new case in a module traps here, at the end of the run that recorded
   it, after the measurement is over.
3. The main thread's "own" stopped time. `MainLoad.report` (`:921`) sums
   `flipNs + ownNs + collectorWaitNs + acksOwnNs`.
   `MainThreadCounters.ownTotalNs` (`Shell.swift:234`) adds `edenWaitNs`,
   and the shell's line adds `stopNs` to that (`Scenario.swift:440`). So
   `mainStoppedOwnMsPer10s` of `kajo run --main-ms` and
   `main_stopped_own_ms_per10s` of the shells are two definitions under
   one name. The counters are also copied field by field three times
   (`Shell.swift:724`, `Shell.swift:237`, `Headless.swift:994`).

**The cost.** Architecture: a counter added in `Marking/` is a change in
`MarkingState.swift`, in `Headless.swift` and in `shell-report.py`; the
module does not hide its report. The process's own lessons name the
failure: "Read the line of code that prints a field before saying what it
measures", "Each value a writer can emit is named by the reader".

**The proposal.** A small report type in KajoVM: a field is a name and a
typed value (count, nanoseconds as ms, bytes as MB, ratio, text, absent),
with one formatter and one percentile function (pick one rule and say
which in `docs/CONTEXT.md`). Each module directory gets its report beside
its counters (`Nursery/NurseryReport.swift` and so on); `Headless.swift`
keeps run, test, seal and the composition. Enum names come from the case
(`"\(r.cause)"`, as `stopsByKind` already does for `StopKind`), with an
explicit short name only where the row's text must not change. The main
thread's attribution is one function on `YoungWorkerCounters` with a
`since`, used by `MainLoad`, by `ShellVM.mainThreadCounters` and by the
scenario line. Key names stay as they are, so old rows compare.

**Bound and measure.** No speed claim. Before building: a test that prints
the key list of a `kajo run` line and of a scenario line and compares it
with a committed list. It then shows that the refactor renamed nothing,
and afterwards makes any rename visible. The percentile change moves
numbers: say so in the record and re-read one matrix with both rules.

**Risk and size.** Medium. `Headless.swift` is at KajoVM's root, not in a
core directory, but the reports move into core directories, so this owes
the core tier once. `scripts/check-tier-test.sh` if a script changes.

**Confidence.** Read.

---

## hosts.A2: VM options are parsed in three places

**Where.** `Sources/kajo/main.swift:118` to `:163` (`kajo run`, about 40
flags), `Sources/kajo/Test.swift:20` (`kajo test`, six of them),
`Sources/KajoShellCore/Options.swift:6` and the modes that read it
(`Scenario.swift:155`, `App.swift:25`, `Modes.swift:58` and `:135`,
`DevModes.swift:49` and `:179`), `Sources/KajoApp/Application.swift:382`.
The checks: `Sources/KajoVM/Headless.swift:283` (`configs`).

**What is there now.** `Headless.Options` is the one struct, but each host
fills it by hand, under two spellings (`--marker-slowdown` and
`markerslow=`, `--stall-reloc` and `stallreloc=`, `--reloc` and `reloc=`),
and the same table is written twice:

```swift
case "--stall-reloc": options.stallRelocation = ["plain": 0, "reserve": 1, "skip": 2][value()] ?? 1   // main.swift:143
o.stallRelocation = ["plain": 0, "reserve": 1, "skip": 2][options.string("stallreloc", "reserve")] ?? 1 // Scenario.swift:166
```

A value that does not parse falls to a default: `Int(value()) ?? 0`,
`value() != "off"` (so `--stalls of` is on), `?? 1`. `LaunchOptions`
keeps any `key=value` and no mode says which keys it knows, so
`marker_slow=4` is ignored. `kajo test` takes `--gc` and `--young` but
not `--nursery`.

**The cost.** A matrix row with a misspelt key or value measures the
default and prints a normal row. AGENTS.md has the lesson twice ("check
that an A/B switch switches before believing a null result", "A switch
nobody ran is a switch nobody tested"). Adding an option is three edits
and a usage line; a fourth host (a test, a generated app's launch
argument) is a fourth parser.

**The proposal.** One option table in KajoVM beside `Options`: per option
its name, its launch key, its kind (integer with bounds, fraction, a set
of words) and how it sets the field. Two front ends over it:
`Options.parse(arguments:)` for `--name value` and
`Options.parse(launch:)` for `key=value`. Both refuse an unknown name and
a value that does not parse, with one message. `kajo run`'s usage text is
generated from the table. The shells print `UNKNOWN_KEY=<k>` on the
result line and exit 2 for a key that neither the table nor the mode
declares; `shell-report.py` already lists unknown things as UNKNOWN.

**Bound and measure.** Before building: grep the matrix scripts' keys
against the keys the modes read (`shell-matrix.sh`, `device-rows.sh`,
`remote-session.sh`); any key no mode reads is a finding by itself. After:
`check-tier-test.sh` plus one dry matrix.

**Risk and size.** Medium. The rows' text must not change. Swift tier, and
`check-tier-test` if a script changes.

**Confidence.** Read.

---

## hosts.M3: one reply, seven copies and three parses in Swift

**Where.** Target side: `Sources/KajoVM/Shell/ShellPrimitives.swift:156`
and `:180` (`lineBytes`), the sink (hosts.M1),
`Sources/KajoDev/Server.swift:511` (`deliver`), `:659` (`send`). Client
side: `Sources/KajoDev/ClientHost.swift:465` to `:491`, `:507` (`check`),
`Sources/KajoDev/JSON.swift:182` (`string`), `:271` (`appendJSONString`),
`Sources/KajoVM/Shell/ShellPrimitives.swift:229` (`encode`). Requests, the
same shape: `Server.swift:377` to `:433`, `Request.swift:24`.

**What is there now.** A reply of n bytes written by the image:

1. `lineBytes`: heap to `[UInt8]`; for pieces, `out += b` with no
   capacity reserved.
2. `bytes.first == 123, bytes.last == 125, !bytes.contains(10),
   !bytes.contains(13), String(validating: bytes, as: UTF8.self) != nil`:
   two scans, then a third that builds a String of the whole line to
   learn it is valid, and drops it.
3. The sink's `Data(bytes)` and Foundation parse (hosts.M1).
4. `deliver`: `Array("{\"v\":1,\"kind\":\"reply\",\"conn\":".utf8)` built
   for every line, and a slice copied to compare with it.
5. `send`: `var bytes = line; bytes.append(10)`, a full copy per
   connection (an event goes to every open session).
6. The client's reader: `buffer += chunk[...]`.
7. `ClientHost.check`: the bounded reader builds a `JSONValue` tree; each
   object gets an array of pairs and a `Set<String>`, each string an
   array filled byte by byte and a `String(validating:)`.
8. `writeJSON(out)`: the tree printed again, strings byte by byte.
9. `String(decoding:)`: a validation and a copy.
10. Primitive 154's `encode`: `m.newString(Array(s.utf8))`, a copy to an
    Array and a copy into the heap.

Then the image's own `Json read:`. A request makes the same trip in the
other direction with steps 7 and 8 in `ProtocolServer.handle`.

**The cost.** Per reply: about seven copies of the line and three full
parses or validations in Swift (2, 3, 7 with 9), an allocation per JSON
value in 7. The check itself is the design (ADR 0011: the host hands the
image only what the writer wrote from a value the reader accepted), and
the pieces-against-one-String choice was measured per direction
(`docs/decisions/11-large-bytes.md`); neither is questioned here. What
was not measured is how much of a round trip the hosts' passes are.

**The proposal.** In three steps, each only if the bound says so.

1. Cheap, no design change: validate UTF-8 in primitive 161 without
   building a String; `writev` of the line and the newline in the stream
   (hosts.R1) and no per-connection copy; the two prefix arrays as
   statics.
2. `ShellValue` gets a case for text that is already checked UTF-8 bytes,
   so 9 and the first half of 10 go: the line goes from the writer's
   bytes into the heap in one copy.
3. A one-pass check that a line is already in the writer's canonical
   form, with no tree; the bytes are forwarded when it holds and the
   present parse and print runs when it does not. This is a second
   reader of one grammar, so it needs its property in the protocol
   fuzzer: whenever the check accepts, `writeJSON(parseJSON(bytes))`
   equals the bytes.

**Bound and measure.** The cheating build exists as a broken variant:
"`ClientHost` hands the image the bytes it read"
(`docs/modules/developer-ui.md`, "Broken variants run by hand"). Run the
scripted session's `class.hierarchy` and `package.selectors` steps with
it and with the sinks cut out (hosts.M1's counter). If the two together
are under 3 percent of those round trips, do step 1 only. Measure after
on the same steps and on `protocol_rtt_p50_ms` (`debugstop=1`).

**Risk and size.** Step 1 small, step 2 medium (every switch over
`ShellValue`), step 3 medium with the fuzz property and the test
`theClientTransportTrustsNothingTheSocketSends`. Swift tier and the
protocol fuzzer.

**Confidence.** Read for the passes. The share of a round trip is not
known; that is the point of the bound.

---

## hosts.R2: two view hosts, one protocol written twice

**Where.** Dispatch: `Sources/KajoApp/AppKitHost.swift:119` and
`UIKitHost.swift:99`. `set`: `AppKitHost.swift:206`, `UIKitHost.swift:177`.
`get`: `:234`, `:213`. `invoke`: `:259`, `:237`. Colours:
`AppKitHost.swift:295` with `AppKitViews.swift:661`, `UIKitHost.swift:301`.
`setStyles`: `AppKitViews.swift:575`, `UIKitHost.swift:272`. `openURL`:
`AppKitViews.swift:679`, `UIKitHost.swift:207`. The data sources' argument
parsing: `AppKitViews.swift:81`, `:103`, `:202`, `:227`.

**What is there now.** Each host has its own handle table, its own
`create / set / get / frame / origin / add / call` switch with the same
argument-count and geometry checks, its own colour-name table and its own
parse of the style triples. ADR 0010 says the protocol is the same on
both; the two files already disagree:

- `set color: 'purple'` (also brown, teal, yellow) is a colour on iOS and
  `.clear` on the Mac: UIKit's `color` knows the names, AppKit's `color`
  does not, only `editorColor` does.
- `highlight` as a background is yellow at 0.4 alpha on the Mac and yellow
  at 0.3 on iOS.
- The first round's AppKit text view is dead code: `make9c` takes
  `textView` before `make` (`AppKitHost.swift:122`), so `make`'s case
  (`:193`), `textView(_:)` (`:204`), two cases of `set` and `get` and
  `invoke`'s `appendLine` and `clear` (`:270`) are never reached.

The outline's and the table's models (ids, children, pages, the asked
set) are toolkit-free logic inside `NSOutlineViewDataSource` and
`NSTableViewDataSource` classes.

**The cost.** The UIKit host has six kinds and the Mac thirteen. Giving
iOS an outline or a table means writing `setChildren`, `setTree`,
`setRows`, `setRowsAt` and their refusals again, and every later fix
twice. A test of the protocol has to ask the host what it supports
(AGENTS.md's `View class>>supports:` lesson) partly because the two
tables are separate.

**The proposal.** A core in KajoApp with no toolkit import: the handle
table; the op and the property as enums parsed once; the dispatch with
its checks; the colour names as an enum; the style triples; the outline
and table models. Two leaves: making a native view of a kind, reading and
writing one property of it, binding a model to the toolkit's data source,
the events. The dead first-round path goes.

**Bound and measure.** No speed claim. Before building: list every op,
property and colour each host accepts (a test can print it from the two
switches' enums once they exist) and decide each difference. After:
`ViewWrapperTest` 202 of 202 headless, in the Mac shell and on the
iPhone.

**Risk and size.** Large. The tests of the wrappers and the tools' real
target tests guard it; `just apps`, `just new-check`, the Mac shell's
tests mode and the iPhone's. Swift tier.

**Confidence.** Read.

---

## hosts.M4: image timers on the global queue

**Where.** `Sources/KajoDev/ClientHost.swift:436` (the client transport's
`timer` op), `Sources/KajoVM/Processes/External.swift:248` (`startDelay`).

**What is there now.**

```swift
DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(ms))) { [self] in
    post(ShellEvent(kind: .timer, target: target, timeNs: ShellVM.now()))
}
```

Every Delay and every tools timer (request timeouts, the reconnect
backoff, the reaper) is a block on the default-QoS concurrent queue the
whole process shares.

**The cost.** A timer fires when a pool thread at default QoS gets a core.
The record has the cost: five kernel-test VMs in one process starved these
timers and the reconnect test failed 6 times in 8
(`docs/decisions/34-gate-speed.md`); the kernel tests run as two parts
since, 1840 s under the sanitizer against 1060 at five
(`docs/modules/gate-speed.md`, open question 2, "make the bundle's timers
independent of its load"). On the phone a default-QoS thread under load
runs on the efficiency cores. Nothing records how late a timer fired.

**The proposal.** One timer queue per VM (and one per `ClientHost`): a
serial queue with a QoS chosen on purpose, or one timer thread with a
heap. Each fire records its lateness (fired minus due) into a counter
with a maximum. The `VMLife` cell and the "a late timer fires into
nothing" rule stay as they are (`docs/decisions/46-delay-outlives-vm.md`).
Also stamp the `timer` event with the time it was due, not `now()` at the
fire (AGENTS.md: the time it happened).

**Bound and measure.** Before: the lateness counter alone, on the present
queue: p50, p99 and max idle and under the storm, Mac and iPhone, and in
the suite with five kernel parts. If the maximum under load is under a few
milliseconds everywhere but the suite, the change is a gate-time change
only; say so. After: the same, and the kernel tests at five parts.

**Risk and size.** Small in KajoDev (Swift tier). `startDelay` is in
`Processes/`, a core directory: core tier, `DelayEndTests`, the idle test
(no timed wait in an idle VM: a serial queue with nothing scheduled does
not wake).

**Confidence.** Read for the code and the record; the device effect is a
guess until the counter exists.

---

## hosts.M5: a queue hop for every line written

**Where.** `Sources/KajoDev/Server.swift:659` (`Connection.send`),
`ClientHost.swift:655` (`ClientConnection.write`); the threads:
`Server.swift:235`, `:300`, `ClientHost.swift:382`, `Client.swift:68`;
`ServerStats`: `Server.swift:723`.

**What is there now.** A line is written by a block on the connection's
serial queue (`queue.async { ... write ... }`), so that a client that
stops reading never blocks a VM thread. One local round trip therefore
wakes six threads: the client's writer queue, the target's reader thread,
a VM worker, the target's writer queue, the client's reader thread, the
client's main thread. The reader threads are Foundation `Thread`s with no
QoS set and the queues have none. `ServerStats` takes one `NSLock` six or
seven times per request and keeps a record per request (up to 20 000,
each with the kind's String) in every serving process, though only the
scenario line and the link probe read them.

**The cost.** Per line written: one thread wakeup that an empty socket
buffer does not need. Per request: two of the six wakeups. The QoS of the
transport's threads is whatever the default gives (AGENTS.md: "Default
pthread attributes give workers QoS `default`"; "Log the QoS each thread
actually got").

**The proposal.** In the stream of hosts.R1: when nothing is pending,
write inline with a non-blocking send under the lock that orders writes;
queue only the remainder of a short write. The order holds because the
queue is empty and the lock is held. Give the reader threads and the
queue an explicit QoS and print the priority they got on the serve line.
Make the per-request records opt-in (the scenario and the probe ask for
them).

**Bound and measure.** Before: a counter of sends that found nothing
pending (the share the fast path would take) and the round trip of a
small request: `protocol_rtt_p50_ms` in `debugstop=1`,
`served_service_p50_ms`, `scripts/link-probe.sh`. A cheating build that
writes inline and blocking is enough on loopback to see the ceiling.

**Risk and size.** Medium, after hosts.R1. It touches "never closed under
a write" (the reader's last step would have to take the same lock); the
`lateWrites` tests guard it. Swift tier, protocol fuzzer, sanitizer under
load.

**Confidence.** Inferred: I read the code; I did not find a measured
loopback round trip in the scratch files.

---

## hosts.A3: a Release app links the VM's tools

**Where.** `Sources/KajoApp/Application.swift:307` and `:365`
(`KernelBench`); `Sources/KajoVM/Headless.swift:140` (`run` of kasm
files); `Sources/KajoVM/Loader/KasmParser.swift`, `Assembler.swift`,
`FuzzEntry.swift` (`FuzzEntry`, `FuzzDriver`), `KernelCompilerProbe.swift`,
`KernelRun.swift`; `Package.swift:29` (KajoVM is one target).

**What is there now.** `KajoApp` depends on `KajoVM`, and KajoVM is the
core plus the kasm text assembler, the headless runner with its reports,
the fuzz entries and their corpus driver, and the compilers' probe ("test
and fuzz support only", its own comment). A Release app calls into them
in one place: `kajo-bench=<kernel.kasm>` among its launch arguments loads
kasm files and runs them before any window. Module 11b used it once (Debug
against Release, 1.005 and 0.997, `docs/modules/distribution.md:468`);
since 11b both configurations link the same prebuilt VM, and no script
runs it.

**The cost.** ADR 0014's rule is that a Release app links none of
KajoDev, KajoCompiler or KajoShellCore, and `just new-check` reads the
binary for it. The same question is not asked of the tools inside KajoVM:
a shipped app carries a text-to-method path and a file-reading launch
argument it never uses. It is also a mode nothing uses. I did not measure
the bytes; the Release `libKajoVM.a` in `.build/release-tests` is one
object of 1.5 MB of text, so the split by file needs a link map.

**The proposal.** Two steps. First, remove `KernelBench` from KajoApp (or
move it to KajoAppDevelopment, where a Debug build can still run it).
Second, a target `KajoVMTools` for the kasm parser and assembler,
`Headless.run` and `test`, the reports' text, `FuzzEntry`, `FuzzDriver`
and `KernelCompilerProbe`; `kajo`, the fuzz targets, KajoCompiler,
KajoShellCore and the tests depend on it; KajoApp does not.
`new-check.sh` gets rows for it: no `KasmParser`, `FuzzDriver` or
`Headless` symbol in a Release binary, with a positive control.

**Bound and measure.** Before building: a link map of the Release sample
(`-Wl,-map`) summed by source file gives the bytes the tools take; if it
is a few tens of kilobytes, do the first step only. After: the binary's
size and the new `new-check` rows.

**Risk and size.** First step small. Second step large: `Loader/` is a
core directory, the image loader and the assembler share
`MethodBuilding`, and `package` access across targets needs care. Core
tier.

**Confidence.** Read for the dependency and the one caller; the size is
not measured.

---

## hosts.R3: `ShellBridge` holds one queue twice

**Where.** `Sources/KajoVM/Shell/ShellBridge.swift:67` to `:129` (events)
and `:158` to `:222` (requests).

**What is there now.** Two sets of the same five things: a mutex, an
array with a head index, a Semaphore oop with its pending-root handle,
and `post`, `register`, `take`, `putBack`, `unregister`. The line that
takes the queued signal's root is written four times:

```swift
let h = sem.flatMap { s in ref.map { $0.rootPending(s) } } ?? -1  // as post (item 16)
```

**The cost.** The review fixes' item 16 (a signal holds what it will
signal) and item 19 (put back on a full heap) were each applied to both
queues by hand. The two differ already in small ways (compaction at 1024
against 256; only the second has an `open` gate).

**The proposal.** One generic `SignalledQueue<Element>` in the same file
with the five operations and the lost-wakeup comment once; the bridge
holds two. The protocol's `open` flag stays in the bridge.

**Bound and measure.** No speed claim: the generic type is specialised in
the module. The tests are the existing ones (`ShellTests`,
`ReviewFixesPart2Tests` for item 16).

**Risk and size.** Small. Swift tier.

**Confidence.** Read.

---

## hosts.R4: "run this Process to its end on the main thread", seven times

**Where.** `Sources/KajoApp/Application.swift:125`,
`Sources/KajoAppDevelopment/Serving.swift:232`,
`Sources/KajoShellCore/App.swift:41`, `DevModes.swift:78`,
`Scenario.swift:217`, `:374`, `:606`.

**What is there now.**

```swift
let end = ShellVM.now() + 10_000_000_000
while rt.vm.state(of: p) != .terminated && ShellVM.now() < end { rt.turn(.wake) }
```

with small differences (`runTurn` with 2 or 5 ms, a `usleep`, a
debugger-stop probe). `state(of:)` takes the held lock and the host lock
and enters and leaves the VM; the turn enters and leaves it again.

**The cost.** If the Process waits on anything that is not a main turn (a
background Process, a Delay), the loop spins the main thread at full
speed for up to ten seconds with the run loop blocked. In
`KajoAppRunner.start` with `stopsForDebugger` each pass of a waiting
`open` also spawns a `Debugger isStoppedProcessId:` Process and polls it
with `usleep(200)` for up to two seconds. The app's own `open` normally
ends in one or two turns, so this is the failure path, on the launch.

**The proposal.** One `ShellRuntime.run(_:bound:)`: turn; when a turn ran
no slice and the Process is not terminated, wait on the wake (a
semaphore the `wakeMain` callback also signals) up to the bound instead
of turning again; answer the result or why not. The debugger probe is
asked once per wait, not once per pass.

**Bound and measure.** A counter of turns the loop made per call, printed
with `launch step=app-opened`; today's sample should read a handful.

**Risk and size.** Small. Swift tier, `just new-check`.

**Confidence.** Read.

---

## hosts.A4: what the bootstrap compiler need not do twice

**Where.** `Sources/KajoCompiler/Syntax.swift:431` to `:476` (`TypeNode`),
`:626` to `:759` (the type grammar); `Tonel.swift:293`, `:338`, `:477`;
`KernelBuilder.swift:113` to `:148` and `:164` to `:180` (the records);
`KernelBuilder.swift:39` (`package(ofFile:)`).

**What is there now.** The bootstrap compiler stays the image build's
compiler and the oracle (`docs/modules/kernel-live.md`); the scanner, the
method parser, the analysis and the code generation must be double and
are compared (CompilerTest, the corpus, the fuzzer's kernel mode). Two
things are double without that reason:

1. The type grammar. Code generation reads no type, yet the Swift parser
   builds `TypeNode` trees for every kind (name, variable, block, union,
   meta, alternatives) with a `description` whose only reader is a test
   that compares it with the kernel's `Parser>>describeType:`.
2. The hand-over to the kernel. The build passes five private text
   records to `Smalltalk`: definitions joined by line breaks, class types
   joined by byte 30, signatures, and sources in chunks of 2000
   (`recordDefinitions:`, `recordClassTypes:`, `recordSignatures:`,
   `recordSources:`). Each of Types 1 and Types 2 added a format on both
   sides. The kernel has its own Tonel reader. `package(ofFile:)` reads
   `package.st` by searching for `#name`, a third STON reading in one
   module.

**The cost.** Every change to the type syntax (the direction record lists
more: narrowing, protocol types) is a change in Swift, in the kernel, in
the corpus and in the fuzzer's seeds. Every new piece of class metadata
is a new record format and two slicers.

**The proposal.** For 1: the bootstrap keeps only what it needs, the end
of a type (the `>` rule with the nesting of `[` and `(`), which both
Tonel readers must agree on and which stays in the corpus; the kernel's
parser is the one type parser, and the image build asks it to read every
signature once (it already runs Smalltalk in the fresh image). For 2:
measure first, then let the build hand the image each file's text and
path and let the kernel's reader record comments, categories, sources,
types and signatures.

**Bound and measure.** For 2, before anything: the time the kernel's
Tonel reader takes over `kernel/` in a built image against the present
record steps (the build prints its total; the kernel's round-trip test
has its `us`). The build must not get slower by more than its own
spread, and the garbage must not raise the image's entry high-water mark
(AGENTS.md: "An image's size follows the entry table's high-water mark").
For 1: the count of corpus entries and fuzz seeds that exist only for
type trees.

**Risk and size.** Medium each. `canonical-tonel.sh --check` byte
identity, `TypesTests`, `SignatureTests`, the syntax fuzzer in both
modes. Swift tier and the Smalltalk tier.

**Confidence.** Read for the Swift side. Inferred for the kernel side: I
did not read `kernel/Compiler` or the kernel's Tonel reader.

---

## Smaller items

Not written out in full; each is small and stands alone.

- **A post from the main thread wakes a background worker.**
  `ShellBridge.post` ends in `pushExternal`, which signals an idle worker
  (`External.swift:130`), and `ShellRuntime.deliver` then drains the
  signal itself in the turn it runs at once (`ShellRuntime.swift:177`).
  Existing iPhone rows show the price and that it is small:
  `scenario=idle events=0` has `workers_cpu_ms` 24.1 to 24.5 and
  `workers_mj` 0.4 to 0.5 over 10 s for 1266 frame posts
  (`~/kajo-scratch/main-offload/part5/matrix-iphone/scenarios.txt`), and
  `events=1000` has 65 to 70 ms and 16 mJ of 2618
  (`events.txt`). A post that the caller follows with a turn could skip
  the wake. Mechanical; under 1 percent of the row's energy.
- **`DevTarget.run` waits 20 ms timed and ignores `preempted`**
  (`Sources/KajoDev/Target.swift:97`). An idle headless target wakes 50
  times a second, and a main-affine Process that needs more than one 4 ms
  turn gets one turn per 20 ms: the VM calls `wakeMain` only from another
  worker (`Scheduling.swift:141`). Wait untimed and turn again at once
  after a preempted turn, as `ShellRuntime` does.
- **`setStyles` converts each triple's offsets on a bridged string**
  (`AppKitViews.swift:580`, `TextOffsets.swift:14`). `t.string` is an
  `NSString`-backed String, so each `utf8.index(offsetBy:)` walks from the
  start. `makeContiguousUTF8()` once per call would make it linear. A
  guess: the op is not among the eight slowest in the typing rows.
- **`f1`, `f2`, `f3` and `percentile` live in KajoAppDevelopment**
  (`Stats.swift`), so `KajoShellCore/Telemetry.swift` imports the serving
  module to format a number, and `KajoApp/Frames.swift` has its own
  copies.
- **`decode` and `shellValue` are the same function**
  (`ShellPrimitives.swift:212`, `Shell.swift:758`).
- **The Edit menu is built twice** (`Application.swift:432`,
  `Product.swift:314`).
- **`EventCollector` and `EventLines`** (`Sources/kajo/Test.swift:84`,
  `Sources/KajoShellCore/Modes.swift:159`) are one class twice.
- **`ProtocolServer.deliver` and the JSON writer allocate small arrays per
  call** (`Server.swift:514`, `:524`; `JSON.swift:275` to `:282`, `:291`).
- **The shells' native rows bind a dylib; the product links a static
  library** (`apps/Shared/build-images.sh` against the generated
  `scripts/build-native.sh`). Calls from native code into the VM go
  through a stub in the first and are direct in the second. A guess that
  it matters; AOT 2 measured the product itself.

## Read and found good

- `ShellVM`: one relaxed load per checked call, the message built out of
  line; `close` under one lock with a report; no oop crosses the surface.
- The event queue's argument (one signal per event, the root taken under
  the bridge's lock) holds as written.
- `ShellRuntime`: the wake is coalesced with one atomic exchange; the
  frame account renews by the clock without a link; the follow-up holds
  the runtime weakly. A generated app starts no display link and no
  timer, so an idle app has no periodic wake from the host.
- The launch: nothing waits on a name or the network before the window;
  the development half starts at the second frame or after a bound.
- `ProtocolServer`: the unpaired bounds come before the token, the token
  compare is constant time, the accept loop survives `EMFILE`, reports
  made under the lock are called after it.
- The JSON reader's bounds and its duplicate-key set; the request checks;
  `TargetAddress` and `TXTRecord` trust nothing; the fuzz target states
  the read-back properties.
- `ClientHost`: tokens and project directories never reach the image.
- The generator: a function of its input, refusals as values, the native
  library keyed by a hash of image, tool, compiler and flags.
- The bootstrap compiler: chains walked by loops, `unowned` back
  references, one depth limit shared with the kernel, the identifier rule
  asked of KajoVM.
- `Package.swift`: strict memory safety on every target; the Release app's
  three excluded modules are checked on the binary.
- Checked against the records and dropped: one primitive call per property
  and batching (ADR 0010: 0.02 ms a call, not needed), strings crossing by
  copy in view calls, the empty turn per frame, pieces against one String.

## What I read, and what I did not

Read whole: `Sources/KajoVM/Shell/` (3 files), `Sources/KajoVM/Headless.swift`,
`Sources/KajoApp/` (8), `Sources/KajoAppDevelopment/` (4),
`Sources/KajoShellCore/` (10), `Sources/KajoDev/` (9),
`Sources/KajoGenerator/` (2), `Sources/kajo/` (2),
`Sources/KajoCompiler/` (6), the four fuzz targets, the two shells' Swift
and specs, `apps/Shared/build-images.sh`, `Package.swift`, ADR 0010, the
decision part of ADR 0011 and of ADR 0014, `docs/reviews/2026-11-10/tools.md`.

Read in part, for the functions this report quotes:
`Processes/External.swift`, `Workers/Run.swift`, `Workers/Safepoint.swift`,
`YoungCollection/Rounds.swift` (the blocking region),
`ObjectModel/KernelPrimitives.swift` (primitive 140),
`Marking/MarkingState.swift` (the enums).

Not read whole, searched only: `docs/modules/shells.md`, `app-project.md`,
`development-protocol.md`, `developer-ui.md`, `phone-transport.md`,
`distribution.md`, `project-directory.md`, `shell-close.md`,
`closed-shell-calls.md`, `first-launch.md`, `kernel-image.md`,
`gate-speed.md`; the records in `docs/decisions/` (11, 34 and 46 in part);
`docs/PROCESS.md` and `docs/VERIFICATION.md` (headings only).

Not read: ADRs 0012 and 0013; the Xcode project files and Info.plists;
`apps/Shared/smalltalk` and `devsession`; every script but by search;
the tests; `kernel/`, `tools/`, `types/`; `Sources/KajoAOT`; the rest of
the VM core.

## Bugs met on the way

Not looked for; each is where I read.

1. `Sources/KajoDev/Client.swift:141`: a reply that arrives after its
   request timed out is stored in `replies` and never removed
   (`send` removes only the key it still waits for, `:185`). A long-lived
   `kajo mcp` keeps every late reply, however large.
2. `Sources/KajoVM/Headless.swift:921` against
   `Sources/KajoVM/Shell/Shell.swift:234` and
   `Sources/KajoShellCore/Scenario.swift:440`: the main thread's "own"
   stopped time is three different sums under two nearly equal names
   (hosts.A1, item 3).
3. `Sources/KajoApp/AppKitHost.swift:295` against `UIKitHost.swift:301`:
   `set color:` knows purple, brown, teal and yellow on iOS only
   (hosts.R2).
4. `Sources/KajoDev/Target.swift:97`: a preempted main turn in a headless
   target is followed by a wait of up to 20 ms (smaller items).
5. `Sources/KajoVM/Headless.swift:404` against
   `Sources/KajoAppDevelopment/Stats.swift:4`: two percentile rules in one
   result row (hosts.A1, item 1).
