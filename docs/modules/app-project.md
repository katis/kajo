# Module 11a: the app project

Status: brief (2026-11-06). The first step of the owner's distribution
shape (2026-11-05, AGENTS.md Decisions and `docs/PLAN.md`'s "later" row):
a developer's own app is a generated Xcode project over the Kajo package,
the phone runs the developer's development build installed with Xcode,
and serving the development protocol is a property of that build. This
module builds the generator, what a generated app links, and serving by
build configuration, and proves them with a sample app developed live
from the Mac on the Mac, the iPhone and the iPad.

Not in this module: `Kajo.dmg` and the wizard's window (a later step calls
this module's generator), TLS, a snapshot saved on the phone, the second
round of view wrappers on UIKit, anything about App Store submission.

## What it hides

How a Kajo app is put together: which Swift it links, how its images are
built, what differs between a development and a release build, and how a
development build is found and paired. A developer sees a directory of
Tonel files, an Xcode project with two targets, and a running app the
tools can connect to. A later wizard sees one function that writes a
project.

## 1. What a generated app links

Today the AppKit and UIKit hosts (the view wrappers' native side, the
display link, the pairing screen, the event plumbing) live in
`apps/KajoShell-macOS/Sources` and `apps/KajoShell-iOS/Sources`, and
`KajoShellCore` carries the measurement modes beside the runtime. A
generated app should hold almost no Swift: an entry point that hands the
bundled image to a library.

- The platform hosts become library products of the root package (one
  product with an AppKit and a UIKit half, or two; decide and say why).
  The shells in `apps/` are rebuilt on them, so there is one
  implementation of every wrapper and the shells' tests and matrix keep
  testing what apps run.
- A release app links no measurement modes (tests, golden, scenario,
  devsession, serve) and no bootstrap compiler.
- A release app's binary holds no development protocol: no server, no
  Bonjour advertisement, no pairing code, no `KajoDev`. This is a second
  lock beside the release image refusing to serve. Check it on the built
  binary (symbols and size), not on the project file.
- The public surface a generated app's Swift uses is small and named in
  the doc; it is what later versions must keep compatible.

## 2. The generator

`kajo new <Name>` with a bundle identifier, an optional team and where
Kajo comes from (a path, or a URL with a revision), writing a directory:

- an xcodegen spec with a Mac target and an iOS target (iPhone and iPad)
  that share one Tonel directory;
- the Tonel directory with a small starting app (a window, a label, a
  button that changes the label) and one SUnit test of it;
- the few lines of Swift each target needs, the Info.plist settings, a
  `.gitignore`, a short README;
- the Xcode project itself when xcodegen is installed.

Debug bundles a development image (the kernel and the app's package, the
protocol served); Release bundles a release image (`--release`, sealed)
of the same sources. The images are built in a build phase with the `kajo`
of the pinned Kajo checkout, as `apps/Shared/build-images.sh` does for the
shells; measure what that costs on a first build and on an incremental
one.

The generator's code is a library the CLI calls, so the Mac app's wizard
can call it later. Its output is deterministic and tested byte for byte
for a fixed input. It takes a developer's input, so it refuses rather than
traps: names that are not valid for a class prefix, a Swift module and a
bundle identifier, a directory that exists and is not empty, a path that
escapes.

The pinned dependency: the tests use a path to the working tree. The real
form is a URL with a revision, but the repository is private and has no
releases; do not invent a release process, raise it as a question.

## 3. Serving is a property of the development build

For generated apps this replaces 9d's "serving only by launch argument"
(the owner, 2026-11-05):

- A Debug build serves over TCP with the Bonjour advertisement from launch,
  with no argument. The token is per install as in 9d. The advertised name
  tells apps apart on one device.
- The pairing screen is not a panel over the app. It is reached from the
  running app and closed again; propose the way in on each platform (a
  shake on iOS and a menu item on the Mac is the default to beat) and
  raise it as a question.
- A Release build has no listener and its Info.plist has neither
  `NSBonjourServices` nor `NSLocalNetworkUsageDescription`.
- The shells in `apps/` keep `mode=serve` by argument; they are
  measurement tools.

## 4. The round trip

The evidence that the shape works, scripted and repeatable:

1. Generate the sample app, build both targets in both configurations
   from clean with 0 warnings.
2. Run the Debug app on the Mac, the iPhone and the iPad. From the Mac,
   connect by Bonjour name with the CLI and with the tools.
3. Change a method of the running app (the button's action); the change
   shows in the running app without a restart, and the accepted change is
   written to the project's Tonel directory.
4. Build again; the new build starts with the change.
5. The Release app on each host starts, runs the same app, and does not
   serve.

Measure: the request round trips and the time from the compile request to
the change being live; frames missed by the app while it serves and while
a change lands; cold launch to the first frame on each host; app and image
sizes in Debug and Release; build times, first and incremental.

After a relaunch the app starts from the bundled image, so a change that
was not written to the project is gone. A snapshot on the phone is a later
module; say what this one would need from it.

## Devices

The iPhone 13 Pro and the iPad Pro are attached and signed for team
BDN6M642M2, a free Personal Team: at most three apps installed per device
and ten new app identifiers in seven days. The sample uses exactly one
bundle identifier on the devices, `dev.katajamaki.kajo.sample`; the shell
(`dev.katajamaki.kajo.shell`) stays installed. Devices are reached only
through `scripts/device.sh` (extend it to take a project, a scheme and a
bundle identifier), `scripts/shell-matrix.sh device` and
`scripts/remote-session.sh device`.

## Verification

- Swift tests of the generator: the golden output, every refusal, the name
  rules.
- A gate like `just apps` for the generated project: generate into a
  scratch directory, build both targets in both configurations from
  clean, 0 warnings or fail, and check the Release binaries and plists
  for the protocol.
- Tests that a development build serves at launch and a release build
  cannot, at the level `ShellTests` work at.
- The host refactor changes no behaviour: `just apps`, the Mac shell's
  tests mode at 202 of 202, the iPhone's and the iPad's tests mode at 202
  of 202, and one pass of the scenario matrix on each host beside the
  recorded numbers.
- Every existing gate. If `Sources/KajoVM` changes at all, `interpret` is
  compared instruction for instruction and the aligned A/B is run.

## Decision record

ADR 0014 (proposed): a Kajo app is a generated Xcode project over the
Kajo package, with the development protocol a property of the Debug
configuration. Written with this module's evidence.
