# Distribution: Kajo.dmg, the prebuilt VM and the pinned checkout

Status: briefed 2026-11-07, from the owner's shape of 2026-11-05 and the
answers of 2026-11-07 to module 11a's questions (the Release VM ships
prebuilt as an xcframework so development builds run it; a generated
project pins a checkout the dmg carries, copied to
`~/Library/Application Support/Kajo/<version>/`; the Developer Program is
paid, so Developer ID signing and notarization are available; pairing by
shake and shift-command-P, object-name linking and the Mac sandbox off
stay as built). Module 11b in `docs/PLAN.md`'s Distribution row.

## What it hides

How Kajo reaches a developer's Mac, and how a project they make finds
Kajo afterwards. A developer downloads one `Kajo.dmg`, drags one app to
Applications, opens it, and makes a new app from its File menu; the
project that comes out builds in Xcode for the Mac and the phone with no
network and no toolchain beyond Xcode, runs the Release-speed VM in its
Debug configuration, and serves the development protocol to the Kajo app.
Nothing about how the VM was built, where the checkout lives or how the
image is made shows in the generated project beyond one local package.

## Parts

### 1. The Kajo app

The macOS shell (`apps/KajoShell-macOS`) becomes the product: renamed
`Kajo` (bundle `dev.katajamaki.kajo`), it opens the development image with
the tools (`just dev-image`'s image, built at dmg time) on launch, with the
browser, workspace, transcript and target picker as 9c's `mode=dev` opens
them, and a File > New App… wizard (name, bundle identifier, directory,
the two targets' checkboxes) that calls `KajoGenerator` and opens the
project in Xcode (`open <dir>/<Name>.xcodeproj`). Its measurement modes
stay in `KajoShellCore` behind launch arguments, as today, and are not in
the menus. The app's own serving (Pairing…) stays; its image is the
development image with the protocol, and `kajo` (the CLI) and `kajo mcp`
ship inside the bundle (`Contents/MacOS/kajo`) with a File > Install
Command Line Tool… item that symlinks it into `/usr/local/bin` only when
the developer asks (a question below).

### 2. The checkout and the xcframework

The dmg carries, beside the app, `Kajo-<version>/`: a pristine checkout of
the tagged commit (the sources, `kernel/`, `tools/`, `apps/Shared`,
`Package.swift`, the docs; no `.git`, no `experiments/`, no `references/`)
and `Kajo.xcframework`, the Release build of the products a generated app
links (`KajoVM`, `KajoApp`, `KajoAppDevelopment`, `KajoDev`,
`KajoCompiler`, `KajoShellCore` as one framework per slice, or one
framework with every module; measure the sizes and say which) for
macOS arm64 and iOS arm64 (device), plus the Release `kajo` binary. On
first launch, or when the version is new, the app copies `Kajo-<version>/`
to `~/Library/Application Support/Kajo/<version>/` (and says so in the
Transcript); the generator's `KajoPin` package pins that path. `KajoPin`
gains a `binaryTarget` for the xcframework so both configurations of a
generated app link the prebuilt Release VM: the Debug configuration's VM
is no longer Xcode's `-Onone` build of the package (11a's 2.6 to 4.0 times),
and the `KajoAppBuild` trait and the `-Onone` note in ADR 0014 go. The
image build phase runs the copied checkout's prebuilt `kajo`. The
per-configuration linking (the development half in Debug only) keeps
11a's shape: the Release framework slice carries no development module,
checked by `just new-check` on the generated app's binaries as today.

The pinned checkout exists so a developer can read the kernel's sources
in the browser, edit the tools, and rebuild images; the xcframework exists
so no developer compiles the VM. Both are built by one script
(`scripts/dist.sh <version>`) on the mini: `swift build -c release` of the
CLI, `xcodebuild archive` of each slice from a generated project's spec
(or `xcodebuild -create-xcframework` over the package's products through
a thin wrapper project; find the way that keeps strict memory safety and
`-O` with whole-module optimization, and say which flags the slices were
built with), `kajo build-image --with tools` for the app's image, the
checkout export (`git archive`), the app's build and signing, and the dmg.

### 3. Signing, notarization, the dmg

Developer ID Application for the app, the CLI, every framework slice and
the xcframework; hardened runtime on the app and the CLI with the
entitlements they need (the Kajo app serves on the network and runs no
JIT: none expected beyond the defaults; say which were needed and why);
`notarytool submit --wait` on the dmg, `stapler staple` on the app and the
dmg; `spctl --assess --type open --context context:primary-signature` and
`spctl --assess --type execute` as the gate. The dmg is made by `hdiutil`
with the app, `Kajo-<version>/`, a symlink to Applications and a
README; its name `Kajo-<version>.dmg`, its SHA-256 written beside it. The
credentials (the Developer ID identity in the login keychain, the App
Store Connect API key or app-specific password for `notarytool`) are the
owner's: the script reads a keychain profile name (`notarytool
store-credentials`) from `KAJO_NOTARY_PROFILE` and never a secret from a
file or an argument; without it the script builds and signs and says the
notarization step was skipped.

### 4. Releases

`scripts/release.sh <tag>` from the gate-tiers module grows into: tag the
commit (`v0.<n>`), run `scripts/dist.sh`, and print the `gh release
create <tag> Kajo-<version>.dmg Kajo-<version>.dmg.sha256 --notes-file`
command; the main session runs it (releases are built on the mini and
uploaded; no CI). The version is read from the tag; the app's
`CFBundleShortVersionString` and the checkout's folder name carry it.

### 5. The round trip from the dmg

On the mini, as the developer would: mount the dmg, copy the app to a
scratch Applications folder (`~/Applications` or the scratchpad), launch
it, confirm the copy to Application Support and the tools opening, make
`Sample` with the wizard into a scratch directory, build it in Xcode
(`xcodebuild`) for the Mac in Debug and Release and for the iPhone in
Debug (the sample's profile exists; the iPad with `DEVICE=` as 11a's
rows), run `scripts/app-roundtrip.sh` against the generated project
(extend it to take a project directory, so the same rows come from a
dmg-made project), and measure the one thing this module changes for the
developer: the Debug build's VM speed (fib in the Debug app against the
Release app, both from the dmg; 11a measured 2.6 to 4.0), its first frame
and its frames missed on the Mac and the iPhone.

## The bar

- `spctl` accepts the app and the dmg on a Mac that did not build them
  (the mini after `xattr -w com.apple.quarantine` on the downloaded copy
  stands in; say so); Gatekeeper opens the app with no override.
- A generated app builds in Xcode from the dmg's checkout with the
  network off (`networksetup` is not to be touched: build with
  `-skipPackageUpdates` and a `SWIFTPM` config that forbids fetching, and
  show the build log fetched nothing).
- The Debug app's VM runs fib within 1.1 of the Release app's from the
  same dmg (today 2.6 to 4.0); its first frame and frames missed are
  11a's or better on the Mac and the iPhone.
- The Release app from a dmg-made project has 0 symbols, strings and
  imports of the development modules (`just new-check`'s checks on it).
- The dmg's size and each part's size are in the doc; the xcframework's
  slices are named with the flags they were built with; `kajo` from the
  bundle runs `kajo test` on the kernel image.
- The generator's byte-for-byte fixture is updated with the `binaryTarget`
  pin in the same commit as the generator.
- Nothing under `Sources/KajoVM` changes (if it must, say so and run all
  18 gates); the tier is Swift outside the core plus `just apps` and
  `just new-check` from clean, and the device rows above.

## Open questions for the owner (to be listed, built as recommended)

- Simulator slices in the xcframework (none recommended: the phone is
  the target, and a simulator slice doubles the build; a later addition).
- The command line tool's installation (a File menu item that symlinks on
  request, recommended, against a `PATH` note in the README).
- An update mechanism (none now; the developer downloads the next dmg,
  and the versioned Application Support folder lets two versions sit side
  by side; Sparkle later if wanted).
- Whether the Kajo app's own development image is sealed against
  installs by a developer (no: editing the tools in place is the point;
  the write-back goes to the copied checkout's `tools/`).

## Not in this module

The App Store, the teaching playground app, PSK-TLS for the phone link,
and a Linux or Intel build.
