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
