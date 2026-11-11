# The project directory decided by the host

Briefed 2026-11-11. A follow-up of the second review (`primitives.F7`,
`docs/reviews/2026-11-10/primitives.md`; the owner's answer of 2026-11-10
in `docs/modules/review-fixes.md`, part 1, open question 1: the host
decides, the tools ask it by a `project` op). Swift outside the core, the
kernel's `ClientTransport` and `tools/`; nothing under the core
directories.

## The problem

When a change is accepted in the tools, the target's reply carries the
files the change touched and the client's transport in the host
(`KajoDev.ClientHost`) writes them into the connection's project
directory with `ProjectWriter`, and removes the files of removed or moved
classes. Which directory that is comes from the image: it is the fourth
argument of primitive 164's `connect` (`ClientHost.swift`, `case
"connect"`: any String becomes `ClientConnection.project`).

So Smalltalk in a development image (a program, a paired client's
`evaluate`, an agent) can `connect` to a target the host holds a token
for, name any directory, and send requests whose replies carry `files`
(it can change `DevSession` live to answer what it likes). The host then
writes `<Tag>/<Class>.class.st` files, creates one-level tag directories
and removes `.class.st` and `.extension.st` files in any directory the
user can write.

The neighbours have it right: primitives 148 and 149 are confined to the
one directory the host opened (`--sources`), no component leading out;
the CLI's and MCP's `--project` come from the person; a token never
enters the image. The project directory is the same kind of thing: where
the host writes on the image's word. The trust boundary is the host's
callback, as it is for tokens.

Part 1 of the review fixes built the finding's second half (a project
remove never takes a directory). This module builds the first.

## The rule

The host decides every connection's project directory. The image never
names one: no op of primitive 164 takes a directory, and nothing the
image sends can change which directory a connection writes to. The image
may ask which directory the host holds for a target, and may ask the
host to ask the developer, as it does for a pairing token.

## What to build

Read first: `Sources/KajoDev/ClientHost.swift` whole and
`Sources/KajoDev/Project.swift`; `kernel/Development/ClientTransport.class.st`;
`tools/Client/DevClient.class.st`, `tools/Windows/DevTools.class.st`,
`tools/Models/TargetPickerModel.class.st` and
`tools/Windows/TargetPickerWindow.class.st`;
`Sources/KajoShellCore/DevModes.swift`, `Product.swift` and `Runtime.swift`;
`apps/Shared/devsession/DevSessionBench.class.st`;
`scripts/app-roundtrip.sh` and `scripts/remote-session.sh`; the pairing
op's path end to end (9d), which is the pattern.

### Part 1: the host holds the directories

1. `ClientHost` keeps a project directory per target, set by host code
   only (a public method; under the host's lock, like the typed tokens).
   The key is the target as the host resolves it (the same resolution
   `connect` does, so a name in the targets file, its address and the
   local socket path name one target; say in the doc how a Bonjour name
   is keyed). A directory is accepted only when it is an absolute path
   of an existing directory; a refusal is a value the caller can show.
2. `connect` takes three arguments (target, client, package). A call
   with four is refused (nil), not accepted with the fourth ignored:
   this is a greenfield project, and an old tools package fails where
   it can be seen. The connection takes its directory from the host's
   table at connect time; a target with none writes no file (the
   replies still arrive).
3. A new op `project <target>` answers the directory the host holds for
   the target (a String) or nil. It is for the tools to show; the path
   is not a secret.
4. Every reader of `ClientConnection.project` and every caller of
   `connect` is listed in the doc with what it does now.

### Part 2: the hosts decide

Each host that passed a directory into the image now sets it in its
`ClientHost` and passes nothing:

- `mode=dev project=<dir>` (and `just tools`): the local target's
  directory, set before the tools open. `DevTools class>>openLocal:project:`
  loses its `project:` part.
- The Kajo app's product mode: the copied checkout's `tools/` for the
  local target, as today (`Product.swift`), through the same setter.
- `mode=devsession target= project=` (the remote session and the app
  round trip): the named target's directory. `DevSessionBench`'s
  `startRemote:package:project:` and `startApp:...project:` lose the
  argument; `DevTools class>>openTarget:name:project:` likewise.
- `kajo run` and anything else that makes a `ClientHost`: read the code
  and say what each does. The CLI's and MCP's `--project` (the Swift
  client, not `ClientHost`) are the person's and stay as they are.

In the image: `ClientTransport class>>connect:client:package:` (three
arguments), `ClientTransport class>>projectOf:`; `DevClient` keeps no
directory (its reconnect sends none) and answers `project` by asking the
transport; `DevTools` keeps none. Update the class comments that say
"given at connect".

### Part 3: the developer chooses a target's directory (recommended)

Today a target connected from the target picker other than `local` has
no project directory at all, so the Kajo app cannot write an app's
changes into its `src/`; only the scripted modes can, by launch
argument. With the host deciding, the host asks:

- A new op `chooseProject <target>`: the host asks the developer for
  the target's project directory in a panel of its own (AppKit: an
  `NSOpenPanel` for directories; the hook is injected like the pairing
  prompt, so tests give a fake and a host without one answers nil). The
  chosen directory goes through part 1's setter. The op answers at once
  whether the host holds a directory for the target now; when the
  developer has answered, a `targets` event follows, as for pairing.
- The target picker gains a "Project…" toolbar item beside Pair, and
  shows each target's directory (the `project` op) in its list or its
  status line.
- In the product mode the choice is remembered per target name in a
  file under the Kajo app's support directory (`KAJO_SUPPORT_DIR` in
  tests), read when the host starts; a remembered directory that no
  longer exists is dropped, not created. The scripted modes remember
  nothing.

What a remembered directory is exposed to, to be written in the doc: a
target that answers under a remembered name (plain TCP until the PSK-TLS
module) can make the host write `.class.st` files into that directory
and remove `.class.st` and `.extension.st` files from it, and nothing
else: `ProjectWriter` takes file names and one tag level only.

### Not in this module

`ProjectWriter`'s rules (built in part 1 of the review fixes), the
protocol's requests, the server side, the phone's shells, primitive
164's number and its Swift entry (the op is a string in the same
callback), the iOS hosts (UIKit has no panel hook; `chooseProject`
answers nil there).

## Tests

Each test that can run on the starting commit is run there in a
worktree and its failure quoted (`failing-before.txt`); a test that
passes there is said to pass.

- `connect` naming a directory (four arguments) is refused, and nothing
  is written anywhere: against a fake target whose replies carry
  `files`, a temporary directory the image named stays empty. On the
  starting commit the file appears there.
- A target with a host-set directory receives the files; a target
  without one receives none; two targets with two directories never
  cross.
- The setter refuses a relative path, a missing directory, a file, and
  a link to a file; a name and its address reach the same entry.
- `project` answers the host's directory and nil; `chooseProject` with a
  fake panel sets it, posts the `targets` event, refuses what the setter
  refuses, and answers nil with no hook.
- Every op with arguments of the wrong count or kind answers nil and
  never traps (one seeded test over `targets`, `connect`, `pairing`,
  `project`, `chooseProject`, `send`, `close`, `timer`).
- The remembered file: written, read at start, a vanished directory
  dropped, a malformed line ignored, never a path with a tab or a line
  break.
- Smalltalk: the tools' tests against `FakeDevClient` for the picker's
  item and the shown directory; `DevClient`'s reconnect sends three
  arguments; a headless image's `projectOf:` answers nil.
- End to end on the Mac, each a row with its output kept:
  `mode=dev project=<tmp>` and a method accepted in the browser lands in
  `<tmp>` (the scripted session); `scripts/app-roundtrip.sh mac` (the
  tools' change in `src/`, rebuilt and there at launch);
  `scripts/remote-session.sh` Mac to Mac with its project rows.

## The bar

- No String the image passes reaches `ProjectWriter(directory:)`: shown
  by the list of part 1's item 4 and by a grep quoted in the doc.
- The tests above; the ones that can fail on the starting commit do.
- `scripts/canonical-tonel.sh --check` rc 0 on every kernel and tools
  commit; the tools' tests and the kernel tests pass.
- The Kajo app's product mode still writes a tools change into the
  copied checkout's `tools/` (`DistributionTests`, with
  `KAJO_SUPPORT_DIR`).
- `just check <starting commit>` on the final code commit (the Swift
  tier: clean build, `swift test`, ThreadSanitizer, kernel tests, apps,
  new-check, the protocol fuzzer) and the Smalltalk tier forced on the
  same commit (`scripts/check-tier.sh --tier smalltalk`), each
  `gates.log` quoted.
- No change under the core directories, so no A/B and no device rows;
  `git diff --stat` over `Sources/KajoVM` quoted (expected empty).
- The devices are not run: the change is in the Mac's host and the
  image's client side. Say so in "not done".

## Open questions for the owner (build the recommended option; list them)

1. Part 3 as a whole: should the developer be able to choose a
   target's project directory from the target picker? Recommended: yes,
   as briefed; without it the Kajo app cannot write an app's changes
   into its `src/` at all.
2. Remembering the choice: per target name across launches in the
   product mode (recommended), or asked again every launch.
3. A four-argument `connect`: refused (recommended) or accepted with
   the directory ignored.

## As built (2026-11-11)

Built from 64db65e in two code commits: 7eebd7c (parts 1 and 2, with the
host's half of part 3: the `chooseProject` op, the panel hook and the
remembered file, which live in the same `ClientHost`) and 3f978e6 (part 3's
user interface: the picker's item and column, the AppKit panel). Nothing
under `Sources/KajoVM` changed (`git diff --stat 64db65e -- Sources/KajoVM`
prints nothing), so no A/B and no device rows; `Sources/KajoVM/Shell/` did
not need to change: the new ops are strings in the existing client
callback.

### Part 1: the host holds the directories

- `ClientHost` keeps `projects`, a table from a target's key to its
  directory, under the host's lock beside the typed tokens. Host code sets
  it through one public setter, `setProject(_:for:) -> Result<String,
  ProjectRefusal>`; `project(for:)` reads it. The setter takes an absolute
  path with no control character, at most 1024 bytes, no `.` or `..`
  component, naming an existing directory (a link to a directory is
  followed for the check and kept as given; a trailing slash goes), and a
  target that resolves; anything else is a `ProjectRefusal` naming why
  (`ClientHost.checkProjectDirectory`).
- **How a target is keyed.** The key is `TargetAddress.description` of
  the address `connect` resolves the name to (`projectKey`, the same
  `resolve` `connect` and `pairing` use). So a name in the targets file,
  its address, the local target's name `local` and the local socket's
  path each name one entry. A Bonjour service is keyed `bonjour:<name>`
  (what `listedTargets` gives a browsed service, and what a name in the
  targets file with a `bonjour:` address resolves to). A target known by
  two different addresses (a phone in the targets file by
  `tcp://host:port` and also seen by Bonjour, which `listedTargets`
  lists separately only when the addresses differ) has two entries; so
  have two spellings of one socket path (`/a/../b.sock`), since the
  address is compared as text. A name the product mode remembers that
  does not resolve when the host starts is held under `bonjour:<name>`,
  the only form a later name can take (a hand-added target's name is its
  address, the targets file is read first).
- `connect` takes three arguments (target, client, package: a String or
  nil); any other count, a package of another kind, is refused (nil) and
  makes no connection. The connection takes `projects[key]` when it is
  made, so a later `setProject` changes the next connection, never one
  that is open; a target with none writes no file and its replies still
  arrive.
- `project <target>` answers the host's directory as a String, or nil
  (the target does not resolve, or the host holds none).
- `targets` and `close` now refuse arguments (nil), as every op refuses a
  wrong count or kind.

**Every reader of `ClientConnection.project` and every caller of
`connect`**, after the change:

| where | what it does now |
|---|---|
| `ClientHost.handle`, `case "connect"` | the only maker of a `ClientConnection`: `project: projects[address.description]`, the host's table, under the lock |
| `ClientHost.run`, the line reader | the only reader of `c.project`: `ProjectWriter(directory: dir).apply(r)` for an `ok` reply with `files` |
| `ClientTransport class>>connect:client:package:` (kernel) | the image's one call of the op, three arguments |
| `DevClient class>>connect:name:client:package:` and `DevClient>>openConnection` (the reconnect) | both through `connectArguments`: `{path. clientName. package}`; `DevClient>>project` asks the host (`ClientTransport projectOf: path`) and keeps nothing |
| `DevTools class>>connect:name:`, `openLocal:`, `openTarget:name:` | no directory; the class instance variable `project` is gone |
| `DevSessionBench start:package:`, `startRemote:package:`, `startApp:...expect:`, `startTyping:`, `startInstances:`, `startPointers:` | through `DevTools openLocal:` and `openTarget:name:` |
| `ToolsProbe` (the Swift tests' fixture) | `open:` and `openRemote:` through `DevTools`; `connect:naming:` sends a four-argument connect on purpose and expects nil |
| the Swift tests | `ToolsTests`, `PhoneTransportTests`, `ReviewFixesPart2Tests`, `ProjectDirectoryTests`, `DistributionTests`: three arguments, the directory through `setProject` |

The grep the bar asks for (`grep -rn "ProjectWriter(directory:" Sources`):

```
Sources/KajoDev/CLI.swift:213:            let done = try ProjectWriter(directory: dir).apply(result)
Sources/KajoDev/MCP.swift:71:            let done = try ProjectWriter(directory: dir).apply(result)
Sources/KajoDev/ClientHost.swift:478:                do { try ProjectWriter(directory: dir).apply(r) } catch {
```

The first two are the CLI's and MCP's `--project`, the person's argument
(the Swift client; no image involved). The third's `dir` is `c.project`,
which only line 379 sets (`ClientConnection(id:address:project:
projects[address.description])`), and `projects` is written only by
`setProject(_:key:)`, called by the public setter (host code),
`chooseProject`'s completion (the host's panel's answer) and
`useProjectMemory` (the host's file). No String of the image reaches it.

### Part 2: the hosts decide

- `setHostProjects(host, target:, directory:, memory:)` (KajoShellCore)
  is the one path from a host's launch argument to the setter; it prints
  `project target=<t> dir=<d>` or `project=refused target=<t> why=...` on
  the console.
- `mode=dev project=<dir>` (and `just tools`): the local target's
  directory, set after `serveProtocol` has added `local` and before
  `DevTools openLocal:` is spawned.
- The Kajo app's product mode: `ProductPaths.toolsProject(after:)` (the
  copied checkout's `tools/` after a copy or a present copy, none
  otherwise) as `project=`, through `DevMode` and the same setter; and
  `ProductPaths.projectMemory` handed to `DevMode`, applied after it.
- `mode=devsession [target=<t>] project=<dir>`: the session's target's
  directory (`local` without `target=`), set after the targets file is
  read; `startRemote:package:` and `startApp:...expect:` lost the
  argument, `scripts/remote-session.sh` and `scripts/app-roundtrip.sh`
  pass `project=` to the shell as before and needed no change.
- `kajo run` makes no `ClientHost` for the image (its VM has no client
  callback, so primitive 164 answers nil there); `ClientOptions.connect`
  (the CLI and MCP) makes one only to resolve a name and read the targets
  file's token, and never calls `connect` on it. The CLI's and MCP's
  `--project` are unchanged. Generated apps (`KajoApp`) attach no client
  transport. The test shells (`LocalTools`) set the directory with
  `setProject`.
- In the image: `ClientTransport class>>connect:client:package:`,
  `projectOf:`, `chooseProject:`; `DevClient` keeps no directory and
  answers `project` by asking; `DevTools` keeps none; the class comments
  that said the directory was given at connect say the host holds it.

### Part 3: the developer chooses (built, the recommended option)

- `chooseProject <target>`: nil unless the target resolves and the host
  has a panel (`ClientHost.setDirectoryPrompt`, injected as the pairing
  prompt is). The panel gets a prompt naming the target and the directory
  held now; its answer goes through the setter. The op answers at once
  whether the host holds a directory for the target; when the developer
  has chosen and the setter took it, a `targets` event follows (value: the
  name as the image gave it). A choice the setter refuses changes nothing,
  posts nothing, and the panel shows why (the completion answers the
  text); a cancel changes nothing.
- AppKit: `PairingScreen` (macOS) conforms to `DirectoryPresenter`
  (KajoAppDevelopment) with an `NSOpenPanel` for directories only;
  `attachClient` sets the hook when the presenter is one, on the main
  thread after the turn that asked. The iOS `PairingScreen` is not a
  `DirectoryPresenter`, so the hook is never set there and `chooseProject`
  answers nil.
- The target picker: a fourth column `Project` (the `project` op per row,
  empty when none) and a toolbar item `Project…` (id 6) beside Pair; its
  status says to choose in the shell's panel, or that the image runs
  without a shell that has one. A `targets` event lists the rows again.
- Remembered (the product mode only): `ProjectMemory`, the file
  `<support>/project-directories` (`~/Library/Application
  Support/Kajo/project-directories`; `KAJO_SUPPORT_DIR` moves it), a
  comment line then one `name<TAB>directory` line per target name, written
  whole and renamed into place on every choice. A line whose name is not a
  target name (1 to 64 bytes, no control character) or whose directory is
  not an absolute path without control characters is ignored and never
  written, so neither part can hold a tab or a line break; the last line
  of a name stands; a file past 1 MiB or not UTF-8 holds nothing. Read
  when the host starts (`useProjectMemory`, after the local target's
  own directory, so a developer's choice for `local` wins): each entry
  goes through the setter, a directory that no longer exists is dropped
  from the file and never created. The scripted modes (`mode=dev`
  launched by hand or `just tools`, `mode=devsession`) remember nothing.
- `mode=dev` and the product mode do not browse Bonjour (as before), so
  their picker lists `local`, `~/.kajo/targets` and hand-added targets;
  a phone is chosen for by its name in the targets file or its address.

**What a remembered directory is exposed to.** A target that answers
under a remembered name, or at an address the name resolves to (plain
TCP until the PSK-TLS module; an unauthenticated Bonjour name), can make
the host write `<Name>.class.st` and `<Name>.extension.st` files at the
directory's root and `<Tag>/<Name>.class.st` one tag level down (creating
that tag directory), and remove such files (and a tag directory its last
file leaves empty) there, and nothing else: `ProjectWriter` takes file
names and one tag level only, follows no link and removes no directory
with anything in it. The image chooses none of it: it can only name a
target and ask the host to ask the developer.

### Tests, and how each did on 64db65e

Each test that compiles on the starting commit was run there in a scratch
worktree (since removed; the raw output is the main session's
`failing-before.txt`).

- `ProjectDirectoryTests.aConnectThatNamesADirectoryIsRefusedAndNothingIsWritten`:
  fails on 64db65e: `conn == nil → false, conn → 1` and "the image
  named a directory and the host wrote into it: [\"Planted.class.st\"]".
- `ProjectDirectoryTests.everyOpWithArgumentsOfTheWrongCountOrKindAnswersNil`
  (seeded, 300 argument lists per op over `targets`, `connect`,
  `pairing`, `project`, `chooseProject`, `send`, `close`, `timer`,
  the shapes each op takes skipped): fails on 64db65e with 503 issues,
  `close` 222 (answered `false` with arguments), `targets` 228 (the
  list), `connect` 3 (a four-argument connect accepted).
- `DevelopmentTest>>testTheClientTransportNamesNoDirectory` (kernel):
  fails on 64db65e, "Assertion failed" (no `connect:client:package:`).
- `DevClientTest>>testAReconnectNamesTheTargetClientAndPackageButNoDirectory`
  (tools): errors on 64db65e, "a FakeDevClient does not understand
  #setClient:package:".
- `TargetPickerModelTest>>testTheProjectItemAsksTheHostAndTheRowsShowTheDirectory`
  (tools): errors on 64db65e, "a TargetPickerModel does not understand
  #projectSource:".
- Cannot run on 64db65e, because the API they test does not exist there:
  `eachTargetWritesOnlyIntoItsOwnDirectory`,
  `theSetterTakesOnlyAnExistingDirectoryAndANameIsItsAddress`,
  `theProjectOpsAnswerTheHostAndTheDeveloperChoosesInItsPanel`,
  `theRememberedDirectoriesFile`, `ProjectDirectoryToolsTests
  .theToolsChooseThroughTheHostAndTheirChangesLandThere` (a development
  image with the real transport: the picker's Project… reaches a fake
  panel, the picker shows the directory, the image's own four-argument
  connect is nil, a browser's compile lands in the chosen directory) and
  `DistributionTests.theProductModeWritesAToolsChangeIntoTheCopiedCheckout`
  (under `KAJO_SUPPORT_DIR`: the product's `toolsProject` through
  `setHostProjects`, a fake local target's file lands in the copied
  checkout's `tools/Models/`, and a remembered directory is read).
- Older tests moved to the three-argument connect and the host's setter:
  `ToolsTests`, `PhoneTransportTests` (the four- and five-argument
  connects now both refused), `ReviewFixesPart2Tests
  .aReplysLineIsTimedWhenItWasRead`.
- The new Swift suites ran once under `swift test --sanitize=thread` with
  twelve busy loops: 12 tests in 3 suites passed in 55.4 s, no report.

### The bar

- No String of the image reaches `ProjectWriter(directory:)`: the table
  and the grep above.
- The tests: the five that can fail on 64db65e do; the rest cannot run
  there.
- `scripts/canonical-tonel.sh --check` rc 0 on 7eebd7c (in a worktree)
  and on 3f978e6; 249 kernel tests, 292 in the development image (the
  tools' included), all passing.
- The product mode writes a tools change into the copied checkout's
  `tools/`: `DistributionTests.theProductModeWritesAToolsChangeIntoTheCopiedCheckout`.
- End to end on the Mac (raw output with the main session's
  `end-to-end/`):
  1. `mode=devsession classes=0 project=<tmp>` (the scripted session on
     the local target, through the setter `mode=dev` uses): `project
     target=local dir=<tmp>`, and `DevSessionBench.extension.st` and
     `DevSessionTarget.extension.st` in `<tmp>` (the compiled
     `benchAnswer` and the defined `failingStep`). `mode=dev
     project=<tmp>` prints the same line and opens; with a missing
     directory it prints `project=refused target=local
     why=no_such_directory:_...` and the tools open with none.
  2. `scripts/app-roundtrip.sh mac` (3 launches): 0 failures; the tools'
     shell printed `project target=app dir=<Sample>/src`,
     `tools_change_written=1`, the rebuilt app `starts_with_change=1` by
     its Bonjour name, the Release app does not serve, 0 frames missed in
     the app's live window (3780 of 3780).
  3. `scripts/remote-session.sh mac ... idle loopback 2` (Mac to Mac
     over TCP): 2 sessions, `project target=target dir=<out>/proj-r3`,
     `Shell-Bench/DevSessionTarget.class.st` written there by the
     define-and-retry step, every step done including the dropped link.
- No change under the core directories: `git diff --stat 64db65e --
  Sources/KajoVM` is empty, so no A/B and no device rows.

`just check 64db65e` on 3f978e6 (the Swift tier, the protocol fuzzer;
swift-test 419 + 161 tests, ThreadSanitizer 0 reports, 249 kernel tests,
the fuzzer "libFuzzer build: ok" and 360 541 runs):

```
2026-11-11 14:17:03 3f978e6 check-tier swift: 21 files from 64db65e...HEAD (64db65e...3f978e6) and the working tree
2026-11-11 14:17:03 3f978e6 start clean-build (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 14:17:25 3f978e6 end clean-build rc=0 22s
2026-11-11 14:17:25 3f978e6 start swift-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 14:27:49 3f978e6 end swift-test rc=0 624s
2026-11-11 14:27:49 3f978e6 start tsan (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:36:49 3f978e6 end tsan rc=0 4140s
2026-11-11 15:36:49 3f978e6 start kernel-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:38:35 3f978e6 end kernel-test rc=0 106s
2026-11-11 15:38:35 3f978e6 start apps (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:40:38 3f978e6 end apps rc=0 123s
2026-11-11 15:40:38 3f978e6 start new-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:44:45 3f978e6 end new-check rc=0 247s
2026-11-11 15:44:45 3f978e6 start fuzz-protocol (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:46:56 3f978e6 end fuzz-protocol rc=0 131s
2026-11-11 15:46:56 3f978e6 check-tier done swift failed=0 5393s
```

`scripts/check-tier.sh --tier smalltalk 64db65e` on 3f978e6:

```
2026-11-11 15:47:06 3f978e6 check-tier smalltalk: 21 files from 64db65e...HEAD (64db65e...3f978e6) and the working tree
2026-11-11 15:47:06 3f978e6 start build-image (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:47:08 3f978e6 end build-image rc=0 2s
2026-11-11 15:47:08 3f978e6 start dev-image (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:47:11 3f978e6 end dev-image rc=0 3s
2026-11-11 15:47:11 3f978e6 start kernel-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:48:56 3f978e6 end kernel-test rc=0 105s
2026-11-11 15:48:56 3f978e6 start tools-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:50:56 3f978e6 end tools-test rc=0 120s
2026-11-11 15:50:56 3f978e6 start compiler-tests (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:56:00 3f978e6 end compiler-tests rc=0 304s
2026-11-11 15:56:00 3f978e6 start golden (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:57:13 3f978e6 end golden rc=0 73s
2026-11-11 15:57:13 3f978e6 start mac-shell-tests (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-11 15:57:47 3f978e6 end mac-shell-tests rc=0 34s
2026-11-11 15:57:47 3f978e6 check-tier done smalltalk failed=0 641s
```

### Deviations

- Two code commits, not three: the host's half of part 3 (the
  `chooseProject` op, the panel hook, `ProjectMemory`) is in
  `ClientHost` beside part 1 and went in with parts 1 and 2; 3f978e6 is
  part 3's interface (picker, panel).
- The setter does not resolve a link to a directory: it checks the target
  of the link and keeps the path as given (the developer's choice; no
  `realpath`, so no `unsafe` in KajoDev for it).
- The setter also refuses control characters, `.` and `..`, and paths
  past 1024 bytes; `targets` and `close` now refuse arguments, and
  `connect` refuses a package that is neither a String nor nil (the
  seeded test's rule, every op).
- The panel's completion answers a text for the panel to show (why a
  choice was refused, or that it was taken but could not be remembered),
  which the brief did not name.
- The brief's end-to-end row 1 names `mode=dev`; the scripted session is
  `mode=devsession`, which sets its directory through the same
  `setHostProjects`. Both ran; the method landing in the directory is
  the devsession's.
- The local scripted session missed 58 frames of 273 (window opening and
  the session's steps), and the remote one 57 and 44; nothing in this
  module touches the frame path. The main session ran the baseline at
  the hand-back: the Mac shell built at 64db65e (in a worktree) and at
  4a73211, `mode=devsession classes=0 project=<tmp>`, five launches a
  side, interleaved, nothing else running. The starting commit missed
  44, 48, 46, 43 and 44 frames of 255 to 266 (longest turn 13.7 to
  15.7 ms); the head 46, 45, 43, 57 and 45 of 261 to 268 (14.3 to
  16.7 ms); no session failed, and both sides wrote the session's two
  extension files into their project directory. The misses sit in the
  window-opening steps on both sides, so the 58 is the starting
  commit's own range with one high launch, not this module's.

### Not done

- The devices are not run: the change is in the Mac's host and the
  image's client side (the iOS host has no panel, so `chooseProject`
  answers nil there; nothing else of the phone's changed).
- `mode=dev` and the product mode still do not browse Bonjour, so a phone
  is chosen for by its targets-file name or its address.
- Two spellings of one address (a socket path with `..`, a phone by
  address and by Bonjour name) are two entries.
- No UI to clear a target's directory (choose another one).

### Open questions (decisions only)

1. Part 3 as a whole: built, as recommended (the picker's Project…).
2. Remembering: per target name across launches in the product mode, as
   recommended; the scripted modes remember nothing.
3. A four-argument `connect`: refused (nil), as recommended.

Answered by the owner on 2026-11-11: yes, yes and refused, all three as
recommended and as built.
