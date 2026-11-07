# Module 11a: the app project

Status: built, 2026-11-06, from the brief of the same day (84ed59d). The
first step of the owner's distribution shape (2026-11-05, AGENTS.md
Decisions and `docs/PLAN.md`'s "later" row): a developer's own app is a
generated Xcode project over the Kajo package, the phone runs the
developer's development build installed with Xcode, and serving the
development protocol is a property of that build. ADR 0014 (proposed)
records the decision.

**The devices' sample rows ran on 2026-11-07** once the owner had
signed the mini's Xcode in again ("The sample on the devices" in
Measurements): the round trip on both devices, three findings fixed the
same day (60 Hz on the iPhone, 35 s to a Debug build's first frame, the
script's by-address fallback), the Bonjour name seen from the Mac and
the round trip run by name on both devices once the owner allowed Local
Network for the sample on each (the same evening).
What follows was written on 2026-11-06. Everything on the Mac
ran: the generator, both targets in both configurations from clean with
0 warnings, the Debug app serving from launch, the CLI and the tools
connecting by its Bonjour name, a change landing live and written to the
project's `src/`, the rebuilt app starting with it, and the Release app
starting without serving. On the iPhone 13 Pro and the iPad Pro the
refactored shells ran (202 of 202 kernel tests and one pass of the
scenario matrix on each, 0 frames missed in every scenario), but the
sample app could not be built for either device: `xcodebuild` (outside
the sandbox, as the earlier device runs) answers "No Accounts: Add a new
account in Accounts settings" and "No profiles for
'dev.katajamaki.kajo.sample' were found". A new bundle identifier needs a
development profile, which Xcode makes only with the team's account
signed in; the shell's existing profile still signs the shell, so the
account the owner signed in on the morning of 2026-11-06 is no longer
seen by `xcodebuild`. Signing in is the owner's. The commands that run
the device rows once it is done are in "Not done".

Not in this module (the brief): `Kajo.dmg` and the wizard's window, TLS,
a snapshot saved on the phone, the second round of view wrappers on
UIKit, App Store submission.

## What it hides

How a Kajo app is put together: which Swift it links, how its images are
built, what differs between a development and a release build, and how a
development build is found and paired. A developer sees a directory of
Tonel files (`src/`), an Xcode project with two targets, and a running
app the tools can connect to. A later wizard sees one function,
`AppProjectGenerator.write(_:into:)`.

## 1. What a generated app links

```
Sources/KajoApp/              the runtime and the hosts; what every app links
  Platform.swift              ShellPlatform, TurnKind
  ShellRuntime.swift          the runtime of 9a, with a tap for a second
                              reader of kernel lines and a slot for what a
                              development build keeps; no transport
  AppKitHost.swift            the AppKit host (was apps/KajoShell-macOS's MacPlatform)
  AppKitViews.swift           9c's AppKit views (was DevViews.swift)
  UIKitHost.swift             the UIKit host (was apps/KajoShell-iOS's IOSPlatform)
  TextOffsets.swift           what both text views share (was KajoShellCore's)
  Application.swift           KajoAppConfiguration, AppDevelopment,
                              KajoAppRunner, KajoApplication.main, the
                              Mac's menu bar, iOS's scene and shake, the
                              cold-launch line
Sources/KajoAppDevelopment/   a Debug build's half
  Serving.swift               9b's socket and 9d's TCP and Bonjour serving,
                              the per-install token, PairingInfo,
                              PairingPresenter (was KajoShellCore's)
  Pairing.swift               PairingScreen for UIKit and AppKit
  Development.swift           Development: serve from launch, the way to
                              the pairing screen, the frame measurement
  Stats.swift                 percentiles and the frame account (was KajoShellCore's)
Sources/KajoShellCore/        the shells' modes only (tests, golden,
                              scenario, demo, dev, devsession, serve)
apps/KajoShell-*/Sources/     the shells' entry points, 54 and 64 lines
```

**One product, two halves.** `KajoApp` is one library product whose
AppKit half is compiled under `#if os(macOS)` and its UIKit half under
`#if os(iOS)`. SwiftPM builds a package per platform anyway, so neither
half costs the other platform anything, and a generated project's two
targets name the same product and call the same entry. Two products would
have made the generated project name a different product per target for
no gain.

**The shells are rebuilt on it.** `apps/KajoShell-macOS` makes an
`AppKitHost(statusWindow: true, keepDisplayAwake: true)` and a
`PairingScreen(style: .statusLine)`; `apps/KajoShell-iOS` a
`UIKitHost(statusLine: true, spinner: true)` and a
`PairingScreen(showsAtOnce: true)`. Those options are all that is left
of the shells' own UI code: the status window and line, the orange
spinner that keeps ProMotion from throttling, and the display assertion
are the measurements' and off in an app. Every wrapper has one
implementation, so the shells' tests mode and matrix test what an app
runs.

**The public surface** a generated app's Swift uses, the part later
versions must keep compatible:

- `KajoAppConfiguration(name:appClass:imageName:workers:heapMiB:)`
- `KajoApplication.main(_:development:) -> Never`
- `Development()` (KajoAppDevelopment), passed only in Debug.

The library's other public names (`AppKitHost`, `UIKitHost`,
`ShellRuntime`, `KajoAppRunner`, `PairingScreen`, `ShellPlatform`) are
for the shells and the tests; an app does not name them.

**What the app runs.** `KajoApplication.main` makes the platform's
application object (`NSApplication` with a menu bar of the app's name,
Hide, Quit and Edit; on iOS `UIApplicationMain` with `KajoAppDelegate`
and the `KajoSceneDelegate` the Info.plist names), the host, and after
the first frame a `KajoAppRunner`: the bundled `kajo/app.img` opened with
two workers and 256 MiB, the app class's `open` run as a main Process at
UI priority, and at the app's second frame (or after a second when no
frame comes) the development half told: the window comes first, and
nothing serving does can hold it ("On the devices" below). The runtime runs without a
display link (turns on wakes and events, ADR 0004's account renewed by
the clock), as the shells' demo mode does. The Transcript goes to
standard output.

**A release app links no measurement modes, no compiler and no
protocol.** `KajoApp` depends on `KajoVM` only. Checked on the built
binaries by `just new-check` every run: the Release binary of either
platform holds 0 symbols of `KajoDev`, `KajoAppDevelopment`,
`KajoCompiler` and `KajoShellCore`, no `_kajo-dev._tcp` or
`kajo-pairing-token` string and no `DNSServiceRegister` import; the
Debug binary holds 1689 to 1706 `KajoDev` symbols and imports
`DNSServiceRegister`. Sizes are in Measurements.

## 2. The generator

`kajo new <Name> --bundle-id <id> (--kajo <path> | --kajo-url <url>
--revision <rev>) [--team <id>] [--directory <dir>]` calls
`KajoGenerator` (Foundation only, a library so the Mac app's wizard can
call it) and writes:

```
Sample/
  project.yml               xcodegen: Sample-macOS and Sample-iOS (iPhone and
                            iPad) over Sources/ and the image build phase
  KajoPin/Package.swift     the pin: Kajo by path, or by URL and revision, with
                            the KajoAppBuild trait; products KajoPin and
                            KajoPinDevelopment
  KajoPin/Sources/...       @_exported import KajoApp / KajoAppDevelopment
  Sources/App.swift         the app's whole Swift (17 lines), both targets
  Info-iOS-Debug.plist, Info-iOS-Release.plist,
  Info-macOS-Debug.plist, Info-macOS-Release.plist
  src/package.st            Package { #name : #Sample }
  src/SampleApp.class.st    a window, a label, a button whose action is pressed
  src/SampleAppTest.class.st  a press changes the label
  scripts/build-images.sh   the build phase
  .gitignore, README.md
  Sample.xcodeproj          when xcodegen is on PATH
```

The Tonel files are in the canonical form the image writes (checked by
writing the package out of an image built from them: byte for byte), so
the first change the tools write back touches only the method changed.

**Debug and Release.** Both configurations build the same sources. The
build phase runs `scripts/build-images.sh`, which builds `kajo` from the
pinned checkout with the toolchain first on PATH in a clean environment
(as `apps/Shared/build-images.sh` does for the shells) into the project's
`.build/kajo/tool`, and then `kajo build-image` of the checkout's
`kernel/` and the project's `src/`: a development image in Debug, a
release image (`--release`, sealed) in Release. The image is built again
only when `src/`, the kernel or `kajo` is newer than it. The Debug
Info.plists name `_kajo-dev._tcp` in `NSBonjourServices` and carry
`NSLocalNetworkUsageDescription`; the Release ones have neither. The
Mac target signs to run locally (`-`), with no hardened runtime and no
App Sandbox, as the shell does.

**Refusals are values.** `AppProjectGenerator.files(for:)` and
`write(_:into:)` answer `Result<_, GeneratorRefusal>`:

- the name: 2 to 30 characters, a capital A to Z first, then letters A to
  Z and digits (a Smalltalk class prefix, a Swift module, an Xcode target
  and a bundle identifier component as it is); not a module every app
  imports or a package a development image holds (Swift, Foundation,
  AppKit, UIKit, Kernel, Tools, Object, Main, ...), nor any name starting
  with `Kajo`;
- the bundle identifier: two or more dot-separated components of letters,
  digits and hyphens, none empty or starting with a hyphen, at most 155
  characters;
- the team: ten capital letters and digits;
- where Kajo comes from: an absolute path, or an `https://`, `ssh://` or
  `git@` URL and a revision of 7 to 40 lowercase hex digits, none with a
  quote, backslash, dollar, backtick or control character (they land in
  the manifest and the build script as written);
- the directory: one that exists and is not empty, one that is not a
  directory, a symbolic link, and a relative path with a `..` component
  (it could leave the directory it is relative to).

The output for a fixed input is the same bytes every time and is tested
against the fixture project (`Tests/KajoCompilerTests/Fixtures/app-project`).

**The pin.** The tests and the gate use a path to the working tree. The
real form is a URL with a revision (`.package(url:revision:traits:)`, the
build script finding Xcode's checkout under
`$BUILD_DIR/../../SourcePackages/checkouts/<identity>`); the repository
is private and has no releases, so that form is generated and tested as
text only, and is an open question.

## 3. Serving is a property of the development build

For generated apps this replaces 9d's "serving only by launch argument".
The shells in `apps/` keep `mode=serve` by argument.

- **A Debug build serves from launch.** `Development.started` calls
  `ShellRuntime.serveTCP` on port 0 with the per-install token of 9d
  (Application Support, mode 0600; on the Mac the app's own folder in it,
  named by its bundle identifier), advertised with Bonjour as
  "**<app> on <device>**" (the Mac's localized name; on iOS the model's,
  "iPhone" or "iPad": the user's name for the device needs an
  entitlement, `gethostname` answers "localhost", and
  `ProcessInfo.hostName` answered "localhost" after 35 s on the main
  thread; Bonjour renames a second device of one model, "Sample on
  iPhone (2)", and the pairing screen shows the name it took), at most 63
  bytes. The TXT record names the image, as in 9d. One line
  goes to standard output, `serving=tcp port=.. addresses=.. name=..`,
  never the token.
- **The pairing screen is reached from the running app and closed
  again.** On iOS a shake (the window, at the end of the responder chain,
  takes `motionShake`) shows the panel of 9d over every Smalltalk window,
  with a Close button beside New token; the next shake hides it. On the
  Mac the app menu's **Pairing…** item (shift-command-P) opens a window
  with the name, the token, the addresses, the listener's state and New
  token; the item or the window's close button closes it. Proposed, and
  an open question.
- **A Release build cannot serve.** It does not link
  `KajoAppDevelopment` (part 1), its Info.plist has neither key, and its
  image is a release image, which refuses to serve (8d). Measured on the
  Mac: no Bonjour service, no `serving=` line, no listening socket.
- **Debug runs an optimized, unchecked VM.** Xcode builds every package in
  its Debug configuration with `-Onone` and `DEBUG`, whatever the app's
  settings (tested: project-level optimization settings and a
  configuration named otherwise do not reach package targets). For Kajo
  that is a checked build, every verifier at every pause. The pin
  enables the package trait `KajoAppBuild`; under it `KajoVM` gets `-O`
  in Debug (`.unsafeFlags(["-O"], .when(configuration: .debug, traits:
  ["KajoAppBuild"]))`) and `Config.swift`'s checked build is
  `DEBUG && !KajoAppBuild`. Whole-module optimization cannot be added
  this way: Xcode's index-while-building passes per-file index outputs and
  the driver refuses `-wmo` ("index output filenames do not match input
  source files"), also with `COMPILER_INDEX_STORE_ENABLE = NO` in the
  project. The gate reads the Debug compile line for both flags.

## 4. The round trip

`scripts/app-roundtrip.sh mac|device <outdir> [launches]` is the round
trip, scripted: generate, build Debug (first and again), cold launches,
10 s serving with no client, a 30 s window while the Mac connects by
Bonjour name with the CLI (five `kajo eval`, one `kajo compile` of the
button's action with `--project src`, then evaluations until a press
shows the change) and with the tools (the macOS shell's `mode=devsession
session=app`: `DevSessionBench startApp:...` opens the browser on the
app's class side, shows `pressed`, accepts a new source and evaluates a
press in a workspace until it answers the new text), the change found in
`src/`, a Debug build again whose relaunched app starts with it, and the
Release build: cold launches and no serving. The device form goes
through `scripts/device.sh` (extended: `PROJECT`, `SCHEME`, `CONFIG`,
`PRODUCT`, `BUNDLE`, which accepts only the shell's and the sample's
identifiers) and falls back to the address on the Mac's network when no
Bonjour name shows, reading the address and the port from the console of
the launch it is about to talk to (each launch listens on a new port; a
rebuilt app that does not answer is a `FAILED` line). A Debug launch with
`kajo-frames=<s>` counts the display's frames beside the app for that
long and quits; any launch with `kajo-launch-report` prints the time from
the process's start (its `kinfo_proc` start time) to the first frame
after `open`, and before it one `launch step=<name> ms=<ms>` line per
step of the launch (window, host-ready, image-opened, app-opened, and in
a development build development-due, pairing-screen, device-name, token,
listener, protocol-started, advertised, development-started), each
stamped when the step ended.

After a relaunch the app starts from the bundled image, so a change that
was not written to the project is gone. A snapshot on the phone (a later
module) would need: a place in the app's container for the saved image
and a rule for which image a launch opens (the bundled one when the
bundle is newer than the snapshot, so a rebuild still wins); the save
from the protocol (8c's `Smalltalk snapshot:` already runs in a
development image, but the protocol has no request for it and a save
stops the world for 0.45 to 0.56 ms plus the write); and an answer for
the project files, which the snapshot would hold but `src/` would not.

## Measurements

### On the Mac

Mac mini (M2 Pro), macOS 27.2, Xcode 27.2, the 120 Hz display. Three
runs of `scripts/app-roundtrip.sh mac`: two on 3b04240 and its working
tree (2026-11-06 12:35 to 12:45, thermal nominal on every line; the
second with the App Nap fix below, its last steps lost to an edit of the
script it was running) and one complete run on 25a7332, the final code
(16:23 to 16:30, after the gates, thermal fair on every line). Ranges
below cover all three; `rt-mac/`, `rt-mac2/`, `rt-mac3/` beside the
gates' directory.

| | Debug | Release |
|---|--:|--:|
| build from clean (packages, image phase, app) | 30.1 to 32.4 s | 42.6 to 42.7 s |
| build again, nothing changed | 2.9 to 3.0 s | |
| build after the tools' change to `src/` | 3.9 to 4.2 s | |
| cold launch to first frame, launches 2 to 5 (ms) | 213 to 255 | 190 to 235 |
| cold launch, first after a build (ms) | 584 to 678 | 560 to 594 |
| app bundle | 10 264 KiB | 7 032 KiB |
| binary | 40 528 B stub + 5 358 896 B debug dylib | 2 121 296 B |
| image | 5 062 784 B (development) | 5 063 256 B (release) |

From `just new-check` (clean DerivedData, 2026-11-06): iOS Release
binary 1 981 584 B, app 6 892 KiB; iOS Debug 5 041 120 B; Mac Debug from
clean 33 s, iOS Debug 16 s, Mac Release 43 s, iOS Release 40 s. The image
build phase alone: 13.0 s the first time (building the project's `kajo`
from a warm compilation cache), 1.3 s with nothing changed (the no-op
`swift build` and the copy), 2.5 s with a source touched or for the
other configuration's image.

**Round trips** (the Debug app on the Mac, by Bonjour name):

| | ms |
|---|--:|
| `kajo eval` as a process (resolve, connect, open, request), 2nd to 5th | 30 to 38 |
| `kajo eval`, the first after the app started | 67, 1022, 1031 |
| `kajo compile` as a process | 32 to 33 |
| compile request to a press showing the change (two processes) | 68 to 70 |
| tools: `method.compile` request | 3.5 |
| tools: `evaluate` request (a press and the label read back through the view hop) | 1.3 to 5.2 |
| tools: `class.hierarchy`, `package.list`, `class.selectors`, `method.source` | 28 to 31, 6 to 11, 3.7 to 4.2, 1.0 to 2.1 |
| tools: the select step (class side, method shown) | 26.5 to 28.0 |
| tools: the compile step (accept to "compiled") | 5.4 to 7.7 |
| tools: the live step (the press answering the new text) | 5.3 to 7.2 |

**Frames of the app** (Debug, `kajo-frames`): with no client 0 of 1260
missed in 10.5 s; over the 31.5 s window in which the CLI and the tools
made 8 sessions and 17 requests and two changes landed, 0 of 3780
missed; after the relaunch 0 of 1008 (runs 2 and 3 alike). The first
`kajo eval` after a launch takes about a second where the next take 33
to 38 ms: Bonjour's first resolution, as 9d measured (0.3 to 0.4 s
there). In the first run the window
measured 13 of 1260 frames idle and missed 333 of 3779 over the live
window, one gap of 2.8 s: the app, launched from a script and not made
frontmost (macOS 14's cooperative activation), was napped by App Nap
while other windows covered it. The frame measurement now holds an
activity (`.userInitiated`, `.latencyCritical`, display sleep off) for
its window; an app a developer leaves behind other windows is napped as
any Mac app is, which would slow its round trips (not measured).

**The Debug VM.** `KajoVM` built as a Debug app builds it (Xcode's
compile line, `-Onone ... -O`, the trait on, file by file) against the
same in Release, one worker, the fixture kernels, two runs each
(2026-11-06 about 12:00, `linkexp/E`): fib 5 134 against 1 678 ms
(3.06x), sends 6 648 against 2 563 (2.59x), alloc 12 086 against 3 002
(4.03x). Without the trait (`-Onone`, a checked build) fib alone did not
finish in two minutes.

### On the devices

The refactored shells on both devices (`scripts/device.sh tests` and
`RUNS=1 scripts/shell-matrix.sh device <out> scenarios`, 2026-11-06
12:45 to 12:52):

| | iPhone 13 Pro (iOS 27) | iPad Pro 12.9 3rd gen (iPadOS 26.7.2) |
|---|---|---|
| kernel tests | 202 of 202 in 5.4 s, nominal | 202 of 202 in 7.1 s, nominal |
| frames missed, all ten scenarios | 0 of 1200 each | 0 of 1200 each |
| main stopped for others, ms per 10 s, storm stw / local / offload | 329 / 32 / 35 | 528 / 50 / 53 |
| ring stw / local / offload | 759 / 58 / 58 | 1403 / 98 / 97 |
| share stw / local / offload | 74 / 43 / 58 | 68 / 55 / 61 |
| thermal | nominal to serious (share offload last) | nominal to fair |

Beside the recorded numbers (shells.md and phone-transport.md "On the
devices": iPhone storm 464 / 43 / 48, ring 1252 / 76 / 81; iPad storm 475
/ 54 / 53, ring 1244 / 101 / 93) every row is within the recorded spread
or below it, and no scenario missed a frame. The macOS shell: tests mode
202 of 202 in 5.1 s; the matrix pass missed 0 frames in every scenario
but the ring under the stop-the-world oracle (286, then 253 on a rerun)
and one launch of storm offload (3; 0 on its rerun), and 1199 in its
first launch, idle, while the display was waking. The ring under the
oracle missed 250 to 297 with the starting commit's shell built and run
interleaved with this one's (251 to 379), so that number is today's
machine, not the refactor (the reserve-and-depth note's 143 was measured
before the collectors review).

The sample app on the devices: see "The sample on the devices" below.

### The sample on the devices

Signing was cleared by the owner on 2026-11-07 and the sample's round trip
(`scripts/app-roundtrip.sh device`) ran on both devices that morning
(11:25 to 11:43, every line thermal nominal, raw rows in the scratchpad's
`sample-iphone/` and `sample-ipad/`). It found three things, fixed the
same day (b440924, c8c18ba, 684e78c) and run again on both devices from
the fixed commit (13:08 to 13:17, every line thermal nominal,
`sample-followup/after-iphone/` and `after-ipad/`; the traced launches
before the fix at 13:02 to 13:04, `before-iphone/`).

**The generated iOS app rendered at 60 Hz on the iPhone.** Every frame
row of the Debug sample read `frames=63 expected=126` per 1.05 s, gaps
16.668 ms: the generated Info.plist lacked
`CADisableMinimumFrameDurationOnPhone`, which the shell's spec has; an
iPhone app without it is capped at 60 Hz. Both iOS plists carry it now
(b440924). The iPad rendered at 120 Hz without the key and still does.

**The Debug sample took 35.2 to 35.6 s to its first frame** (iPhone
35 180 to 35 306 ms, iPad 35 332 to 35 593, five launches each; Release
100 to 130 ms on the iPhone and 221 to 233 on the iPad). The launch trace
(`kajo-launch-report`'s `launch step=` lines, added for this) placed it on
the iPhone in five more launches (35 183 to 35 214 ms): window 44 to 79
ms, image opened 98 to 126, the app's `open` done 100 to 128, and then
`ProcessInfo.processInfo.hostName`, for the service name, on the main
thread for 35.0 s in every launch (35 036 to 35 041 ms), answering
"localhost"; token, listener, the protocol's start and the Bonjour
registration together 23 to 28 ms after it. Not the Local Network permission
and not the token store. Two changes (c8c18ba): the device's part of the
name is the model's on iOS ("Sample on iPhone"; `gethostname` also
answers "localhost", and the user's name for the device needs an
entitlement) and never waits, and the development half starts at the
app's second frame, or after 1 s if no frame comes, so nothing serving
does can come before the window. The iPad's trace was not taken before
the fix; its 35.3 to 35.6 s has the same shape and went with the change.

| | before | after |
|---|--:|--:|
| iPhone Debug, first frame, five launches (ms) | 35 180 to 35 306 | 102.7 to 156.5 |
| iPhone Release (ms) | 100.6 to 129.8 | 101.2 to 114.6 |
| iPad Debug (ms) | 35 331.5 to 35 592.9 | 229.5 to 254.4, 615.6 first after install |
| iPad Release (ms) | 221.0 to 233.4 | 213.9 to 247.0 |
| iPhone, development half started (trace, ms) | 35 160 to 35 190 | 116.0 to 181.0, after the first frame in every launch (due by frame 9 to 26 ms after `open`) |

**The script's by-address fallback kept the first launch's port.** With
no Bonjour name seen, step 5 talked to the live launch's port while the
rebuilt app listened on a new one, so `starts_with_change=0` was the
script connecting to nothing. The fallback now reads the address and port
from the console of the launch it is about to talk to, and no reply is a
`FAILED` line (684e78c). After the fix: `starts_with_change=1` on both
devices, by address.

The Mac's round trip from the same commit (`after-mac/`, three launches,
thermal nominal) is unchanged by the deferred start: Debug first frame
219.5 and 232.5 ms after the first launch (583.8), Release 193.3 to 232.6
(582.8 first), 0 frames missed in every window, by Bonjour name
throughout, the rebuilt app starting with the change, Release not
serving and no listening socket.

The rows after the fixes (the build times and the iPhone's live rows
before them, from the morning's run, beside them where they differ):

| | iPhone 13 Pro (iOS 27) | iPad Pro 12.9 3rd gen (iPadOS 26.7.2) |
|---|---|---|
| Debug build from clean, again unchanged, after the tools' change (s) | 34.0, 4.6, 5.8 (morning: 32.7, 8.4, 5.4) | 31.6, 5.2, 6.1 (morning: 34.6, 9.3, 6.0) |
| Release build from clean (s) | 42.2 (46.4) | 42.3 (46.8) |
| app bundle Debug / Release (KiB) | 10 536 / 7 184 | 10 536 / 7 184 |
| first frame Debug / Release (ms) | 102.7 to 156.5 / 101.2 to 114.6 | 229.5 to 615.6 / 213.9 to 247.0 |
| frames, five 1 s windows after launch | 128 to 130 of as many, 0 missed, gaps 8.334 ms | 0 missed of 124 to 128 |
| frames, 10.5 s serving with no client | 0 of 1264 missed | 0 of 1264 |
| frames, the 30 s live window (8 sessions, 17 requests) | 0 of 3647 | 0 of 3782 (2 short of expected at the edges, 0 counted missed) |
| frames, the rebuilt app (8.4 s) | 0 of 1012 | 0 of 1012 |
| `kajo eval` by address, first / 2nd to 5th (ms) | 302 / 56 to 70 (morning 254 / 56 to 66) | 237 / 70 to 80 (399 / 69 to 75) |
| compile from the CLI, then a press shows it (ms) | 73, 151 (82, 140) | 98, 166 (91, 174) |
| tools: open, select, compile, live steps (ms) | 71.9, 27.1, 16.1, 11.6 (74.2, 16.7, 11.6, 9.7) | 388.7, 30.1, 29.3, 12.4 (592.7, 321.4, 23.4, 14.3) |
| tools: `class.hierarchy`, `method.compile` requests (ms) | 65.0, 9.9 | 382.0, 28.8 |
| the change in `src/`, the rebuilt app starts with it | yes, yes | yes, yes |
| Release serves | no (no Bonjour service, no serving line) | no |
| Bonjour name seen from the Mac | no, then yes (below) | no, then yes |

The tools' own window (the macOS shell's devsession) missed 15 to 20
frames in its 0.3 to 1.2 s of windows opening, as the module's Mac rows
did for the first windows (9c). **The Bonjour name was not seen** on
either device in any run: the sample's `_kajo-dev._tcp` never appeared in
`dns-sd -B`. The likely cause, as for the shells in 9d, is iOS's
Local Network permission for the sample, which is the owner's to grant
on each device (Settings > Privacy & Security > Local Network > Sample);
nothing here answered or dismissed a prompt, and whether one is showing
was not looked at. Until then the
round trip connects by address; once allowed, the `service` row shows
"Sample on iPhone" and "Sample on iPad".

**The owner allowed Local Network for the sample on both devices** the
same evening and the round trip ran once more on each from the final
commit's tree (19:26 to 19:32, thermal nominal on every line,
`sample-bonjour/iphone/` and `ipad/`): the `service` row reads
`Sample_on_iPhone` and `Sample_on_iPad`, every connection went by name
(`addr=bonjour:Sample on iPhone`, `bonjour:Sample on iPad`) and the
rebuilt app answered `starts_with_change=1` on both; Debug first frame
112.3 to 129.5 ms on the iPhone and 243.3 to 251.1 on the iPad (942.4
on its first launch after install), Release 97.9 to 117.9 and 211.8 to
248.1; 0 frames missed in the idle, live and rebuilt windows on both (0
of 1264, 3647 and 1012 on the iPhone; 0 of 1263, 3783 and 1012 on the
iPad); `kajo eval` first request 143 ms on the iPhone and 899 on the
iPad (the first resolution of the name), then 56 to 60 and 74 to 80;
compile to live 153 and 185 ms; the tools' steps open, select,
compile, live 83.6, 24.0, 12.1, 17.8 ms on the iPhone and 297.0, 481.4,
29.4, 15.2 on the iPad. The by-name rows match the by-address rows above
within their ranges but for the first request, which pays the name's
resolution as 9d measured (0.3 to 0.4 s Mac to Mac).

### The kernels against the starting commit

`Sources/KajoVM` changed in one line (`Config.swift`: the checked build is
`DEBUG && !KajoAppBuild`); the trait is never on in the repository's
builds, so the binaries cannot differ but by placement. `interpret`
disassembled from both aligned builds is identical instruction for
instruction (1373 lines; the only two differing lines are the function's
and the next symbol's addresses). The aligned A/B: 0878ea2 against
3b04240, both `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`, five runs interleaved,
`--slice-ms 0`, 2026-11-06 13:00 to 13:05, median (min to max) ms, every
checksum equal on both sides and the published one:

| kernel | workers | 0878ea2 ms | 11a ms | 11a / start | checksum |
|---|--:|--:|--:|--:|---|
| alloc | 1 | 2928.9 (2919 to 2940) | 2941.1 (2936 to 2958) | **1.004** | 41950911 |
| alloc | 8 | 512.6 (446 to 514) | 456.9 (441 to 510) | **0.891** | 42008248 |
| arith | 1 | 2539.8 (2537 to 2547) | 2550.9 (2550 to 2552) | **1.004** | 372800000 |
| arith | 8 | 352.9 (338 to 362) | 336.9 (337 to 343) | **0.955** | 372800000 |
| closures | 1 | 3737.0 (3725 to 3749) | 3712.2 (3708 to 3722) | **0.993** | 210210000 |
| closures | 8 | 485.9 (478 to 508) | 504.5 (484 to 507) | **1.038** | 209214000 |
| fib | 1 | 1698.9 (1690 to 1701) | 1696.4 (1685 to 1702) | **0.999** | 24682992 |
| fib | 8 | 218.4 (217 to 238) | 228.3 (219 to 250) | **1.045** | 24682992 |
| floats | 1 | 3211.4 (3203 to 3219) | 3174.0 (3165 to 3197) | **0.988** | 7499750000 |
| floats | 8 | 423.1 (412 to 452) | 431.7 (415 to 441) | **1.020** | 33747999993 |
| ivars | 1 | 1971.3 (1970 to 1977) | 1971.7 (1968 to 1974) | **1.000** | 36383626 |
| ivars | 8 | 262.3 (252 to 278) | 256.9 (252 to 267) | **0.979** | 71714128 |
| sends | 1 | 2580.9 (2567 to 2591) | 2585.7 (2580 to 2593) | **1.002** | 1066666666666668 |
| sends | 8 | 352.6 (332 to 358) | 344.0 (334 to 363) | **0.976** | 133333335000001 |
| storeheavy | 1 | 2403.5 (2392 to 2411) | 2411.1 (2399 to 2418) | **1.003** | 512000 |
| storeheavy | 8 | 317.9 (308 to 342) | 327.7 (315 to 340) | **1.031** | 512000 |
| walk | 1 | 3608.6 (3578 to 3634) | 3616.8 (3599 to 3648) | **1.002** | 9016009025388544 |
| walk | 8 | 471.2 (464 to 511) | 485.8 (463 to 499) | **1.031** | 1127013096095744 |

One worker within 1.2 percent everywhere; eight workers within their
ranges, which overlap in every row.

## Changes to earlier modules

- 9a, a latent bug: a turn that left work scheduled its follow-up on the
  main queue holding the runtime strongly, and the runtime's platform is
  `unowned`; a runtime whose host was gone before the queue ran the turn
  trapped ("Attempted to read an unowned reference but object ... was
  already destroyed"). The shells' hosts live for the process, so only
  this module's tests met it, in the gate's ThreadSanitizer run, in a
  later test of the same process. The follow-up holds the runtime weakly;
  `aTurnLeftForLaterDoesNotOutliveItsHost` traps without the rule.
- 9a: `ShellRuntime`, `ShellPlatform`, the AppKit and UIKit hosts and
  9c's views moved into `KajoApp`; `ShellRuntime.init` takes the client
  transport's callback (`client:`), no longer makes a `ClientHost`, and
  gained `setEventTap` and `developmentState`. `ShellPlatform` lost
  `showPairing`, `onNewToken` and `askSecret` (now `PairingPresenter`).
  `ShellApp(platform:pairing:)`; every mode takes the presenter.
- 9b to 9d: serving (`serveProtocol`, `serveTCP`, `stopProtocol`,
  `PairingTokenStore`, `tcpPort`) moved into `KajoAppDevelopment` as
  extensions of `ShellRuntime`; a runtime's `clientHost` is the attached
  one (`attachClient`), nil when none was. `PairingTokenStore` has
  `applicationSupport()`.
- 9c: `DevSessionBench startApp:package:class:selector:source:probe:expect:project:`
  and the macOS shell's `mode=devsession session=app`.
- 8a: `Config.swift`'s checked build excludes the `KajoAppBuild` trait;
  `Package.swift` declares the trait and KajoVM's `-O` under it.
- `scripts/device.sh` builds, installs and launches another project and
  bundle identifier (two identifiers allowed).
- Docs: shells.md, developer-ui.md, phone-transport.md,
  collectors-review.md, ADR 0002 and ADR 0010 name the new places.

## Deviations from the brief

- **Xcode cannot link a package product in one configuration.** The
  brief's "Debug links the development half, Release does not" assumes
  it. A package product a target depends on is linked in every
  configuration, and dead stripping keeps most of an unreferenced Swift
  module (its type and conformance records are live): a Release binary
  that depended on the development product without importing it kept
  1224 `KajoDev` symbols and the `DNSServiceRegister` import (2.64 MB
  against 2.12). Built instead: the development product is a dependency
  with `link: false` (built, not linked) and Debug's `OTHER_LDFLAGS` names
  the three objects Xcode prelinks for it in the products directory
  (`KajoPinDevelopment.o`, `KajoAppDevelopment.o`, `KajoDev.o`). This
  relies on Xcode's naming of those objects, which `just new-check`
  checks on every run.
- **A generated project has a third Swift package, `KajoPin`.** Package
  traits are the only way to change how a dependency builds, and an Xcode
  project cannot set a trait on a package it references; a package can.
  The pin is therefore a local package the project references, with the
  dependency on Kajo (path or URL and revision) and the trait; the app
  imports `KajoPin` and, in Debug, `KajoPinDevelopment`.
- **The Debug VM is optimized file by file, not whole-module**, 2.6 to
  4.0 times slower than Release on the interpreter kernels (Measurements).
  The brief did not foresee that Xcode builds packages in Debug as checked
  builds; the trait removes the checks and most of the cost, not all.
- **One Swift file serves both targets** (`Sources/App.swift`), not one
  per target: the code is the same and the plists differ.
- **The device rows of part 4 did not run** with the module (signing,
  above); they ran on 2026-11-07 ("The sample on the devices").

## Tests

- `AppProjectTests` (8): the output for the fixture's input byte for byte
  (paths, order, text, the one executable), the same bytes twice; only
  Debug plists name the local network and every plist parses; the
  development objects only in Debug and `link: false` on both targets; a
  repository pin's manifest and the checkout path, no team setting
  without a team, the package identity from the checkout's name; the name
  rules (accepted, refused, reserved); every refusal as a value (bundle
  identifiers, teams, paths, URLs and revisions, and the accepted forms);
  relative paths with `..` refused; writing (the script's mode, a second
  write refused, an empty directory accepted, a file and a symbolic link
  refused and the link's target untouched, a refused spec writes
  nothing); the generated Tonel compiles with the kernel with no warning,
  its package is the app's, and its SUnit test passes.
- `AppServingTests` (7 since the devices' follow-up: a runner's `start`
  serves nothing until `startDevelopment`, told once; the development half
  starts within its bound when no frame comes; the device's part of the
  name never waits), at ShellTests' level on a host that keeps the
  views' properties: a development build serves at launch with no
  argument (the store's token on the pairing screen, the file 0600, a
  loopback client reads the label through the view hop after a press, a
  wrong token is refused); a development half over a release image does
  not serve, makes no token, reports why, and the app runs; a release
  build has no transport; an app that cannot open says why; the service
  name tells apps apart and fits Bonjour; a turn left for later does not
  outlive its host.
- `just new-check` (the gate): part 1's and 3's binary and plist checks
  on all four products, and the Debug VM's compile line.

## Broken variants run by hand

- `serveTCP` without its release-image check: `aDevelopmentHalfOverAReleaseImageCannotServe`
  fails ("kajo-pairing-token" exists: the token was made before the
  kernel's `DevProtocol start` refused; the server was still nil, the
  image being the second lock).
- The generated project without `link: false`: the Release Mac binary has
  1224 `KajoDev` and 345 `KajoAppDevelopment` symbols and imports
  `DNSServiceRegister`; `just new-check`'s release check fails on it.
- The follow-up turn holding its runtime strongly: `aTurnLeftForLaterDoesNotOutliveItsHost`
  traps the test process with the message the gate's ThreadSanitizer run
  hit.
- The pin without the trait (`linkexp/E`, before the module's code): the
  Debug compile line of `KajoVM` is `-Onone -DDEBUG` only, the gate's
  Debug VM check fails, and fib did not finish in two minutes.

## Unsafe surface

`KajoApp` and `KajoAppDevelopment` build with strict memory safety, so
code moved out of the app targets became checked: 17 `unsafe` sites in
`KajoApp` (AppKit's `unowned(unsafe)` properties read in the views, 9;
the IOKit assertion calls, 3; `sysctl` and `kinfo_proc` for the launch
time, 4; `UIApplicationMain`'s argv, 1) and 7 in
`KajoAppDevelopment`, all moved from `KajoShellCore` (the token file's
`unlink`, `open`, `write`, `rename`; three `String(format:)`). `KajoVM`:
none added.

## Not done

- Nothing of the devices' rows: the sample ran on the iPhone and the
  iPad on 2026-11-07, by address and, once the owner allowed Local
  Network for the sample, by Bonjour name (Measurements). The commands:
  `scripts/app-roundtrip.sh device <out>` for the iPhone and
  `DEVICE=00008027-0012592C0185002E DD=$TMPDIR/kajo-sample-ipad
  scripts/app-roundtrip.sh device <out>` for the iPad; without the
  permission the Bonjour row fails and the script goes on by address.
- The Mac app as a sandboxed or notarized app; the Release build's
  signing for distribution.
- A Debug VM as fast as Release (a prebuilt binary of the Kajo libraries
  would do it; a question).
- App Nap's effect on a development build behind other windows, measured.

## Open questions for the owner

1. **One product with two halves** (`KajoApp`) and a development half
   (`KajoAppDevelopment`), as built? (Decided by the module.)
2. **The way to the pairing screen**: a shake on iOS and the app menu's
   Pairing… (shift-command-P) on the Mac, as built, or something else (a
   three-finger long press, a status-bar item)?
3. **The pin's real form**: the repository is private and has no
   releases. A URL and a revision is generated and tested as text only.
   What should a developer's project pin, and from where (a public
   repository, a release process, the dmg carrying a checkout)?
4. **The Debug VM's speed**: 2.6 to 4.0 times slower than Release because
   Xcode will not compile a package whole-module in Debug. Accept it, or
   ship prebuilt binaries (an xcframework the dmg carries) so a
   development build runs the Release VM?
5. **Linking by object names**: per-configuration linking rests on
   Xcode's `<target>.o` naming, checked by the gate. Accept it, or make
   the development half a dynamic framework embedded by a Debug-only
   build phase?
6. **The App Sandbox for the Mac target**: off, as the shell. A sandboxed
   app needs the network server entitlement in Debug only.

## Gates

On 25a7332 (the last commit that changes code; the first run of the
sequence, on 7835ac0, stopped at the ThreadSanitizer gate on the trap in
"Changes to earlier modules", and every gate ran again after the fix); every output in the
scratchpad's `m11a/gates/`, `gates.log` records the commit and exit
status of each.

Mac mini (M2 Pro), swift.org 6.4.2 first on PATH, Xcode 27.2 for the
apps, 2026-11-06 13:33 to 16:22. "Load" is twelve `yes` busy loops, topped
up every 20 s while ThreadSanitizer under load outlasted their 1500 s.

| gate | result |
|---|---|
| clean build (`--scratch-path .build/clean-check`, removed first) | exit 0, 0 warnings, 18 s (the toolchain's compilation cache, as in 8e and 9d; the full strict-memory-safety compile of KajoApp and KajoAppDevelopment from nothing is in `just apps` and `just new-check`, whose DerivedData start empty, 0 warnings) |
| `swift test` | 352 + 99 passed, 291 + 88 s |
| under load | 352 + 99 passed, 347 + 108 s |
| ThreadSanitizer | 352 + 99 passed, 0 reports, 496 + 2224 s |
| ThreadSanitizer under load | 352 + 99 passed, 0 reports, 686 + 2726 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release on the checked paths, `interpret` 1056 instructions, one indirect branch and one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 352 + 99 passed |
| `just model-check` | 28 + 5 + 15 passed |
| `just soak` | 27 configurations of 1000 seeds each, no failing seed; the resumed modes saving 897 to 990 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.48 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 2.42 million runs, no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 0.62 million runs, no crash |
| `just fuzz protocol 600` | libFuzzer build ok, 1.62 million runs, no crash |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| `just kernel-test` | 202 of 202 |
| `just new-check` | ok: four builds from clean, exit 0, 0 errors, 0 warnings each (Mac Debug 31 s, Release 43 s; iOS Debug 14 s, Release 39 s); Release binaries 2 115 888 B (Mac) and 1 981 648 B (iOS) with 0 symbols of KajoDev, KajoAppDevelopment, KajoCompiler and KajoShellCore, no `_kajo-dev._tcp`, no `kajo-pairing-token`, no `DNSServiceRegister` import, no local-network key, a release image that refuses to serve; Debug products with all of them and a VM compiled with the trait and `-O`; the image phase 13.0 s first, 1.3 s again, 2.5 s touched |

### Gates of the devices' follow-up

On 6ffdb6d (the last commit that changes code; nothing under
`Sources/KajoVM` changed, so the tier for Swift outside the core), one
after another and after the device runs, swift.org 6.4.2 first on PATH,
2026-11-07 13:30 to 14:39, the scratchpad's `sample-followup/gates/`. A
first run on b5ea15e stopped at `swift test`: the development answers'
start-up test expected `start` to serve and now calls `startDevelopment`
(6ffdb6d).

| gate | result |
|---|---|
| clean build (`--scratch-path .build/clean-check`, removed first) | exit 0, 0 warnings, 25 s (the compilation cache; the strict-memory-safety compile of KajoApp and KajoAppDevelopment from nothing is in `just apps` and `just new-check`, 0 warnings) |
| `swift test` | 381 + 115 passed, 418 s |
| ThreadSanitizer | 381 + 115 passed, 0 reports, 681 + 2450 s |
| `just kernel-test` | 205 of 205 |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| `just new-check` | ok: four builds from clean, 0 errors, 0 warnings each; Release binaries 2 215 424 B (Mac) and 2 066 080 B (iOS) with 0 symbols of KajoDev, KajoAppDevelopment, KajoCompiler and KajoShellCore, no Bonjour string or import, no local-network key, a release image that refuses to serve; the Debug VM with the trait and `-O` |
| `just fuzz protocol 120` | libFuzzer build ok, 366 718 runs, no crash |

## Commands

```
kajo new <Name> --bundle-id <id> --kajo <path> [--team <id>] [--directory <dir>]
just new-check [outdir]
scripts/app-roundtrip.sh mac|device <outdir> [launches]
PROJECT=... SCHEME=Sample-iOS CONFIG=Debug PRODUCT=Sample BUNDLE=dev.katajamaki.kajo.sample scripts/device.sh build
<App>.app/Contents/MacOS/<App> kajo-launch-report kajo-frames=10
```
