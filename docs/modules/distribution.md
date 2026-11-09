# Distribution: Kajo.dmg, the prebuilt VM and the pinned checkout

Status: built 2026-11-08 ("As built" below the brief); briefed 2026-11-07, from the owner's shape of 2026-11-05 and the
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

## As built

Built 2026-11-08 on the Mac mini (M2 Pro, macOS 27.2, Xcode 27.2, swift.org
6.4.2 first on PATH; Xcode's compiler is the same 6.4.2). Code commits
db8127e (the generator, its fixture, `kajo-bench`), 36cfff6 (the Kajo app,
`scripts/dist.sh`, release, the scripts), c447392 (xcodegen moved into
Resources), 8523a77 (the round trip's rebuilt-step fallback, the size
listing), 1667cb1 (the generator's xcodegen step macOS only: KajoShellCore,
which now holds the product mode, is the iOS shell's too, and `Process`
does not exist on iOS; the first gate run's `just apps` found it). The dmg
measured below was built by `scripts/dist.sh 0.1` from the clean tree at
c447392; 8523a77 changes two scripts and 1667cb1 adds `#if os(macOS)`
around code that ran unchanged on the Mac, so the dmg's app and
frameworks are what 1667cb1 builds. Nothing under
`Sources/KajoVM` changed; `kernel/` and `tools/` did not change.

**What waited on the owner:** there is no Developer ID Application
certificate and no `notarytool` profile on the mini, so the dmg is
`Kajo-0.1-unsigned-dev.dmg`, signed with the Apple Development identity,
not notarized, and Gatekeeper rejects it (below). Every other bar item
was met.

### 1. The Kajo app

`apps/KajoShell-macOS` (directory kept) now builds the target and scheme
`Kajo`, product `Kajo.app`, bundle `dev.katajamaki.kajo`,
`CFBundleShortVersionString = $(MARKETING_VERSION)` (0.0 from the
repository, the release's version from `dist.sh`). Launched with no
`mode=` it is the product (`Sources/KajoShellCore/Product.swift`,
`ProductMode`); with `mode=` it is the measurement shell as before
(`scripts/mac-shell.sh`, `just tools`, the matrix: updated for the new
name, as are `apps-check.sh`, `weekly.sh`'s busy list and the justfile).

The product, in order: the menu bar (Kajo: About, Pairing… ⇧⌘P, Hide,
Quit; File: New App… ⌘N, Install Command Line Tool…; Edit), so the tools'
Tools menu joins it; after the first frame the checkout copy, then 9c's
`mode=dev` on the bundled development image with `project=` the copied
checkout's `tools/` (so the tools write their changes there, the fourth
question), then one Transcript line saying what the copy did.

- **The checkout copy** (`CheckoutInstaller`): `Contents/Resources/Kajo-<v>`
  to `<support>/<v>` once per version, into `<v>.partial-<pid>` and renamed,
  with a marker file written last; a folder without the marker is moved
  aside (`<v>.incomplete-<time>`), never deleted; a complete one is left as
  it is (the developer's edits stay). `<support>` is
  `~/Library/Application Support/Kajo`, or `KAJO_SUPPORT_DIR`.
- **New App…** (`NewAppWindow`, `NewAppRequest`): name, bundle identifier,
  folder (Choose…), the Mac and iPhone and iPad checkboxes; Create runs
  the generator's checks, writes the project, makes the Xcode project with
  the bundled xcodegen and opens it (`NSWorkspace`, skipped with
  `KAJO_OPEN_XCODE=0`). Refusals are the generator's text in the window.
  `newapp=<Name> bundle=<id> into=<dir> [platforms=]` fills the window and
  presses Create for the scripted round trip.
- **Install Command Line Tool…** (`CommandLineTool`): `<dir>/kajo` as a
  symbolic link to `Contents/Helpers/kajo`, `<dir>` `/usr/local/bin` or
  `KAJO_CLI_LINK_DIR`; an unwritable or missing directory answers the
  `sudo ln -sf` command to run instead (an alert), someone else's `kajo`
  is left alone, our own link from another copy of the app is replaced.
  Tested against scratch directories only; `/usr/local/bin` was never
  written. `cli-install=1` runs the item at launch without the alert.
- **The CLI** is `Contents/Helpers/kajo`, not `Contents/MacOS/kajo`: on a
  case-insensitive volume that name is the app's own executable `Kajo`.
  It finds the bundled xcodegen for `kajo new` through its resolved path.
- **xcodegen** (2.46.0, MIT, its LICENSE in `Resources/xcodegen-LICENSE`)
  ships in `Contents/Resources/xcodegen/{bin,share}`: it reads its presets
  from `../share` beside its `bin/`, and data files under
  `Contents/Helpers` are refused by codesign ("code object is not signed
  at all, in subcomponent .../SettingPresets/...yml"). Without it a
  developer would need Homebrew; the generator does not write a pbxproj.
- **Pairing…** stays (the brief): the window shows the pairing details when
  the app serves over TCP; the presenter is also what the target picker's
  Pair uses for a phone's token (9d's secure field).

Tests: `DistributionTests` (4: the paths and overrides; the copy once per
version, never half, beside another version, an incomplete folder moved
aside; the link only where it may be, never over another file; New App's
refusals and the project over a checkout) and `AppProjectTests` (10).

### 2. The checkout and the prebuilt frameworks

**One framework per module, four of them.** `Prebuilt/` holds
`KajoVM.xcframework`, `KajoApp.xcframework`, `KajoAppDevelopment.xcframework`
and `KajoDev.xcframework` (static frameworks, slices `macos-arm64` and
`ios-arm64`, and since the simulator-slices follow-up of 2026-11-09
`ios-arm64-simulator`, `docs/modules/simulator-slices.md`), `bin/kajo`, `FLAGS.txt` and a `Package.swift` (name `Kajo`)
with a `binaryTarget` each and two products: `KajoApp` (KajoApp, KajoVM)
and `KajoAppDevelopment` (KajoAppDevelopment, KajoDev). One framework with
every module was not built: Release
would then link the development half too and rely on the linker to drop
it, and 11a found that dead stripping keeps most of an unreferenced Swift
module (1224 `KajoDev` symbols); per-configuration linking needs the
development half in frameworks of its own that only Debug names.
KajoCompiler and KajoShellCore are not in it: no generated app links them
(the Kajo app and `kajo` carry them, built from source).

**How they are built**: `scripts/dist-frameworks.yml`, an xcodegen spec of
four framework targets over the checkout's `Sources/`, `xcodebuild build`
once per platform (`generic/platform=macOS|iOS`, and since the
simulator-slices follow-up `generic/platform=iOS Simulator`, `ARCHS=arm64`
each; a generated iOS target asks for arm64 only in the simulator), then
`xcodebuild -create-xcframework` per module. `xcodebuild archive` was
tried first: static frameworks land in `UninstalledProducts`, not the
archive, so `build` it is. The compile lines, read back into `FLAGS.txt`,
are the same for all eight (module × slice), e.g.

```
macOS KajoVM: -O -whole-module-optimization -strict-memory-safety -target arm64-apple-macos15.0 -enable-library-evolution -swift-version 6
iOS KajoVM:   -O -whole-module-optimization -strict-memory-safety -target arm64-apple-ios18.0   -enable-library-evolution -swift-version 6
```

plus `-package-name kajo`; no `-D` flag (no `DEBUG`, so `Config.swift`'s
checked build is off), no `-g` (`GCC_GENERATE_DEBUGGING_SYMBOLS=NO`: debug
info was half of each archive, 30 against 15 MB), no `-enable-testing`.
Strict memory safety and whole-module `-O` held, with 0 warnings and 0
errors on both platforms. Library evolution (`BUILD_LIBRARY_FOR_DISTRIBUTION`)
makes each framework carry a `.swiftinterface`, so a later Xcode can still
import them; inside a module nothing changes (the interpreter is one
module), and the Debug-against-Release numbers below include the cost of
the resilient boundary between KajoApp and KajoVM: none measurable. No
Objective-C header and no clang module (`SWIFT_INSTALL_OBJC_HEADER=NO`,
`DEFINES_MODULE=NO`): the clients are Swift, and the header's
architecture guard broke a client's module scan for x86_64.

**A generated project** (`KajoGenerator`, fixture updated in db8127e with
the generator) has no `KajoPin` any more. `project.yml` names one local
package, the checkout's prebuilt one:

```yaml
packages:
  Kajo:
    path: "/Users/<you>/Library/Application Support/Kajo/0.1/Prebuilt"
```

both targets depend on product `KajoApp` and on `KajoAppDevelopment` with
`link: false`, Debug's `OTHER_LDFLAGS` adds `-framework KajoAppDevelopment
-framework KajoDev` (names Kajo owns, where 11a named Xcode's prelinked
`KajoPinDevelopment.o` and two more), `Sources/App.swift` imports
`KajoApp` and, in Debug, `KajoAppDevelopment`, and the Mac target is
`ARCHS: arm64`. `scripts/build-images.sh` runs `<checkout>/Prebuilt/bin/kajo`
and compiles nothing (11a built `kajo` from the pinned sources on the
first build, 13 s). The wizard's checkboxes are `AppProjectSpec.platforms`
(`kajo new --platforms macOS,iOS`); a project with one target has one
target's plists and spec. `kajo new --kajo` and New App refuse a checkout
without `Prebuilt/Package.swift`, `Prebuilt/bin/kajo` and `kernel/`.
`--kajo-url`/`--revision` (11a's text-only form) are gone with the trait.

**The trait.** `Package.swift` no longer declares `KajoAppBuild` nor
KajoVM's `-O` under it (an `unsafeFlags` setting, which would also have
kept the package from being a remote dependency). `Config.swift`'s `#if
DEBUG && !KajoAppBuild` was left as it is because nothing under
`Sources/KajoVM` may change in this module; the condition is now always
the plain `DEBUG` (removing the dead half is a one-line core change).
ADR 0014 is amended (the trait and the `-Onone` note gone).

`scripts/dist.sh checkout <dir>` exports the working tree (tracked and
untracked files, not ignored) and builds its `Prebuilt/` (2 min); `just
new-check` and `scripts/app-roundtrip.sh` generate against such a checkout,
or against `KAJO_CHECKOUT`, and both take `APP_PROJECT=<dir>` to run on a
project made elsewhere (and `KAJO_NEW`/`KAJO` for which `kajo` runs).

### 3. Signing, the dmg

`scripts/dist.sh <version>`, steps and times from the run (`dist/dist.log`):
export (`git archive` of HEAD, minus `experiments/`, `references/` and the
17 MB of fuzz seeds) 0 s; `kajo` 50 s; frameworks 69 s (34 + 32 + the
xcframeworks); the app 50 s; signing 1 s; dmg 6 s; checks 11 s; 3 min 7 s
in all. The app is built from the exported checkout with
`MARKETING_VERSION=0.1 KAJO_APP_IMAGES=product KAJO=<the built kajo>`, so
its bundle carries only `dev.img` (kernel and tools, 6.1 MB, `just
dev-image`'s), not the measurement modes' images; those modes still answer
behind `mode=` in the app but find no images in a dmg build.

**The checkout lives inside the app** (`Contents/Resources/Kajo-0.1`) and
the dmg's `Kajo-0.1` beside the app is a relative link into it: the app
must find the checkout after the dmg is ejected, and a second copy would
double the dmg. **Signing**, inside out, `codesign --force --options
runtime` (hardened runtime) on `Prebuilt/bin/kajo`, the xcodegen binary,
`Contents/Helpers/kajo` and the app, plain `codesign` on each xcframework,
then the dmg; `--timestamp` with a Developer ID identity, `--timestamp=none`
otherwise. **No entitlement was needed**: no JIT or unsigned executable
memory (the heap's double mapping is data only), no library validation
exception (the app loads only its own code), no App Sandbox. `codesign
--verify --deep --strict`: ok. The identity: `KAJO_SIGN_IDENTITY`, else
the first `Developer ID Application` identity `security find-identity -v
-p codesigning` lists, else the Apple Development one, with the dmg named
`-unsigned-dev`. `notarytool` runs only when `KAJO_NOTARY_PROFILE` names a
profile that `notarytool history` accepts and the identity is Developer
ID: the app zipped, submitted `--wait` and stapled, then the dmg built from
the stapled app, signed, submitted and stapled (two submissions, because
stapling the app changes the dmg). Here it logged "notarization skipped:
KAJO_NOTARY_PROFILE is not set".

**Gatekeeper** (`dist/spctl-*.txt`), the identity that signed `Apple
Development: Joni Katajamaki (A7ZJ8ZA2F7)`, team BDN6M642M2:

| assessment | result |
|---|---|
| `spctl --assess --type execute` Kajo.app | rejected, origin=Apple Development |
| `spctl --assess --type open --context context:primary-signature` dmg | rejected, origin=Apple Development |
| the same on a copy with `com.apple.quarantine` set | rejected |
| the app on that copy's mounted volume | rejected (the attribute did not reach the files of a volume `hdiutil` mounted read-only; Finder's mount of a downloaded dmg propagates it) |

As expected: Gatekeeper accepts only Developer ID signatures, notarized.
These two bar items wait on the owner's certificate and profile.

**Sizes** (`dist/sizes.txt`):

| part | size |
|---|--:|
| `Kajo-0.1-unsigned-dev.dmg` (UDZO, HFS+) | 15 260 306 B |
| Kajo.app | 45 780 KiB |
| `Contents/MacOS/Kajo` (the app, with the compiler and the shell modes) | 3 714 384 B |
| `Contents/Helpers/kajo` | 2 967 696 B |
| `Contents/Resources/kajo/dev.img` | 6 148 456 B |
| `Contents/Resources/xcodegen` | 7 328 KiB |
| `Kajo-0.1` (the checkout) | 25 664 KiB, of which `Prebuilt` 18 612 KiB and the sources, kernel, tools, docs 7 052 KiB |
| KajoVM.xcframework | 10 548 KiB (macos-arm64 3 343 632 B, ios-arm64 3 295 128 B) |
| KajoDev.xcframework | 2 580 KiB (764 248, 765 496) |
| KajoApp.xcframework | 1 684 KiB (637 432, 426 536) |
| KajoAppDevelopment.xcframework | 892 KiB (277 128, 267 752) |
| `Prebuilt/bin/kajo` | 2 967 696 B |

(Each xcframework's size includes its module interfaces and swiftmodules
for both slices.) SHA-256 of the dmg:
`b84f53886693e630c64d21df125b1f1b8a5c736b3156f4f2e508612d95442d32`.

**Re-measured with the simulator slice** (2026-11-09, `scripts/dist.sh
0.2` on 8f06c70 against the script before on 5e3a54e, both signed with
the Apple Development identity and not notarized;
`docs/modules/simulator-slices.md`):

| part | before | with `ios-arm64-simulator` |
|---|--:|--:|
| the dmg | 15 448 949 B | 17 452 775 B |
| Kajo.app | 46 544 KiB | 54 356 KiB |
| `Prebuilt` | 18 932 KiB | 26 728 KiB |
| KajoVM.xcframework | 10 812 KiB | 16 172 KiB (macos-arm64 3 398 560 B, ios-arm64 3 350 072, ios-arm64-simulator 3 349 600) |
| KajoDev.xcframework | 2 580 KiB | 3 856 KiB (764 248, 765 496, 760 920) |
| KajoApp.xcframework | 1 692 KiB | 2 428 KiB (638 160, 427 256, 424 616) |
| KajoAppDevelopment.xcframework | 892 KiB | 1 316 KiB (277 128, 267 752, 266 112) |
| the frameworks step | 69 s | 100 s |
**The bundled `kajo` ran the kernel's tests** on an image it built from
the bundled checkout's `kernel/`: 205 tests, 205 passed, in 4.97 s.

### 4. Releases

`scripts/release.sh v0.<n> [--dry-run]` (`just release <tag>`): refuses a
dirty tree or a tag that is not HEAD, makes the local annotated tag
`v0.<n>` when it is missing, runs `scripts/dist.sh 0.<n>` (which builds
from the tag), writes `notes.md` to fill in and prints the commands; it
pushes and uploads nothing, and for an `-unsigned-dev` dmg it prints no
upload command. `--dry-run` builds and tags nothing (run on 8523a77,
`dist/release-dry-run.txt`). With the default output directory the
printed command is

```
git push origin v0.1
gh release create v0.1 .build/dist/0.1/Kajo-0.1.dmg .build/dist/0.1/Kajo-0.1.dmg.sha256 --title 'Kajo 0.1' --notes-file .build/dist/0.1/notes.md --verify-tag
```

(not run; the script prints absolute paths). The gate-tiers tarball
(`just release-tarball`) is replaced by `just dist <version>` and `just
release <tag>`; the old `just release` (`swift build -c release`) is now
`just release-build`. No tag was created in this module.

### 5. The round trip from the dmg

On the mini, 2026-11-08 06:16 to 07:00, thermal nominal on every line
(rows in the session's `distribution/roundtrip/`):

1. The dmg mounted read-only, `Kajo.app` copied with `ditto` to a scratch
   `Applications/`, the dmg detached.
2. **The one real launch** (no override): `product version=0.1
   checkout=~/Library/Application Support/Kajo/0.1 install=copied`, the
   Transcript line "copied the Kajo checkout to ... (24 MB in 257 ms)",
   the tools opened (`mode=dev ... opened=1`), quit after 25 s. It left
   `~/Library/Application Support/Kajo/0.1/` (25 668 KiB, 717 files: the
   checkout with `Prebuilt/` and the marker). Nothing else under
   `~/Library` was written: no preferences, saved state, caches or
   containers for `dev.katajamaki.kajo` (AppKit's saved state goes to the
   temporary directory, `ApplePersistenceIgnoreState`), and the Sample's
   token file from 11a was read, not rewritten (mtime 2026-11-06 12:20).
3. Every later launch with `KAJO_SUPPORT_DIR` in the scratch directory:
   the copy again (312 ms), New App by `newapp=Sample
   bundle=dev.katajamaki.kajo.sample` (the wizard's own Create path):
   `newapp=ok`, the project pinned to the scratch checkout's `Prebuilt`;
   Install Command Line Tool into a scratch `KAJO_CLI_LINK_DIR`: the link
   made, `kajo version` through it 0.1.0, and `kajo new --platforms iOS`
   through it with `PATH=/usr/bin:/bin` made an Xcode project with the
   bundled xcodegen.
4. **Offline builds** of the wizard's project, all four products from an
   empty DerivedData with `-skipPackageUpdates
   -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
   -scmProvider system`, an empty `-packageCachePath` and
   `-clonedSourcePackagesDirPath`, and `GIT_ALLOW_PROTOCOL=file` (git may
   use no network transport): every build exit 0, 0 errors, 0 warnings,
   Mac Debug 9 s, Mac Release 5 s, iOS Debug 5 s, iOS Release 5 s; the
   logs hold no fetch, clone, download or URL line beyond the command line,
   the one package resolved is `Kajo: <checkout>/Prebuilt`, the cloned
   packages directory holds only `workspace-state.json` and the cache
   none, and no Kajo module was compiled (`roundtrip/offline/`). Not met
   in the strict sense: the network was not off. `networksetup` is not to
   be touched and a `sandbox-exec` profile denying outbound network could
   not be applied inside the session's own sandbox (`sandbox_apply:
   Operation not permitted`; running it outside was refused), so the
   evidence is the flags and the logs.
5. `scripts/app-roundtrip.sh` with `APP_PROJECT` (a copy of the wizard's
   project per run) and `KAJO` the dmg's `kajo`: two runs on the Mac, three
   on the iPhone 13 Pro, one on the iPad Pro.
6. `just new-check` on the wizard's project (`APP_PROJECT`, `KAJO_CHECKOUT`
   the scratch checkout, `KAJO_NEW` the dmg's `kajo`; `new-check.txt`).

**The Debug VM's speed** (the bar: within 1.1 of Release; 11a 2.6 to 4.0):
the Debug and the Release Mac app of the wizard's project, both built
offline from the dmg's checkout, run the fixture kernels inside the app's
own binary (`Sample kajo-bench=<checkout>/Tests/KajoVMTests/Fixtures/kernels/<k>.kasm`,
one worker, three interleaved rounds of three runs, `speed/`):

| kernel | Debug ms, median (range) | Release ms | Debug / Release | 11a |
|---|--:|--:|--:|--:|
| fib | 1361.4 (1352 to 1375) | 1354.8 (1343 to 1364) | **1.005** | 3.06 |
| sends | 2172.5 (2167 to 2181) | 2178.4 (2174 to 2186) | **0.997** | 2.59 |
| alloc | 2862.6 (2851 to 2878) | 2864.9 (2855 to 2926) | **0.999** | 4.03 |

Both link the same prebuilt slice; every checksum is the published one.
(The kernels are faster than 11a's Release numbers too, from the
interpreter-speed module.) Not run on the phone: the kernels' files are on
the Mac.

**First frame and frames missed** against 11a's rows (`speed/frames-and-first-frame.txt`):

| | Mac (2 runs) | 11a Mac | iPhone (3 runs) | 11a iPhone | iPad (1 run) | 11a iPad |
|---|---|---|---|---|---|---|
| Debug first frame, launches 2 to 5 (ms) | 188.4 to 232.3 | 213 to 255 | 98.8 to 113.8 | 102.7 to 156.5 | 223.7 to 240.9 | 229.5 to 254.4 |
| Debug, first launch after a build | 583.3, 618.3 | 584 to 678 | 119.4 to 151.2 | (in the range above) | 455.5 | 615.6 |
| Release first frame, 2 to 5 | 220.8 to 294.1 | 190 to 235 | 98.9 to 119.9 | 101.2 to 114.6 | 216.2 to 247.6 | 213.9 to 247.0 |
| frames missed, 10.5 s serving, no client | 0 of 1264, 0 of 1266 | 0 of 1260 | 0 of 1263 to 1264 (×3) | 0 of 1264 | 0 of 1263 | 0 of 1264 |
| the 30 s live window (8 sessions, 17 requests) | 1 of 3786, 0 of 3784 | 0 of 3780 | 0 of 3648 to 3649 (×3) | 0 of 3647 | 0 of 3783 | 0 of 3782 |
| the rebuilt app (8.4 s) | 0 of 1013, 0 of 1012 | 0 of 1008 | 0 of 1011 to 1012 (×3) | 0 of 1012 | 0 of 1008 | 0 of 1012 |

Debug's first frame and frames missed are 11a's or better on every host
but one Mac live window, which missed 1 frame (a 16.7 ms gap) where the
second run missed none; the Mac's Release launches 4 and 5 were 285.6 and
294.1 ms against 11a's 235 (Release is not this module's change: its
binary is 1 961 232 B against 2 121 296, the same VM). The tools' own
window (the macOS shell's devsession) missed 17 to 22 frames opening, as
in 11a (15 to 20).

Other round-trip rows: Debug build from clean Mac 7.7 s (11a 30.1 to
32.4), again 1.1 s, after the tools' change 1.2 s; Release from clean
6.0 s (42.6); iPhone Debug 7.6 s (34.0), Release 6.8 s (42.2); iPad 7.7
and 7.4 s. App bundles Mac Debug 7 672 KiB (10 264) with a 2 457 328 B
debug dylib (5 358 896), Release 7 128 KiB; iOS Debug 7 688 KiB, Release
7 072 KiB. `kajo eval` by Bonjour name 32 to 38 ms on the Mac, 50 to 70 ms
on the iPhone after a first request of 0.81 s (the name's resolution);
compile to a press showing the change 83 ms on the Mac, 139 to 142 ms on
the iPhone, 129 ms on the iPad. The change was in `src/` and the rebuilt
app started with it on every host; the Release app served nothing (no
Bonjour service, no serving line, no listening socket on the Mac).

**A script finding**: in two of the three iPhone runs the rebuilt app's
Bonjour name still resolved to the live launch's record (the old port),
and the step failed with "Connection refused"; the third run, and the
iPad's, resolved the new one. The step now notes `by_name_failed=1` and
tries the launch's own address from its console (8523a77); the run after
the change passed by name.

**`just new-check` on the wizard's project** (`new-check.txt`): `ok`, four
builds from clean with 0 errors and 0 warnings each (Mac Debug 7 s,
Release 5 s; iOS Debug 5 s, Release 4 s); the Release binaries 1 961 152 B
(Mac) and 1 830 000 B (iOS) with 0 symbols of KajoDev,
KajoAppDevelopment, KajoCompiler and KajoShellCore, no `_kajo-dev._tcp`,
no `kajo-pairing-token`, no `DNSServiceRegister` import, no local-network
key and a release image that refuses to serve; the Debug products with
all of them (1171 KajoDev and 363 KajoAppDevelopment symbols on the Mac);
`kajo_modules_compiled=0 prebuilt_vm_symbols=5559` (the Debug VM is the
prebuilt one: the check that replaced 11a's compile-line check); the image
phase 0.15 s first, 0.02 s again.

### The bar

| item | result |
|---|---|
| `spctl` accepts the app and the dmg; Gatekeeper opens the app with no override | not met at hand-back (rejected, origin Apple Development); **met on 2026-11-09** with the owner's Developer ID Application certificate and `kajo-notary` profile and the script unchanged: see "The release of v0.1" below |
| a generated app builds from the dmg's checkout with the network off, the log fetching nothing | met as far as allowed: the offline flags, git limited to `file`, empty package caches, all four products built and nothing fetched in the logs; the network itself was on (not to be touched) |
| the Debug app's fib within 1.1 of the Release app's | **met: 1.005** (sends 0.997, alloc 0.999) |
| first frame and frames missed 11a's or better, Mac and iPhone | met on the iPhone (and the iPad); on the Mac Debug's first frame is better and its frames 0 missed in every window but one live window of the first run (1 of 3786) |
| the Release app from a dmg-made project has none of the development modules | met (`just new-check` on the wizard's project) |
| the dmg's and each part's size; the slices' flags; the bundled `kajo test` | met (above) |
| the fixture updated with the pin in the generator's commit | met (db8127e) |
| nothing under `Sources/KajoVM` changes | met |
| the gates: the Swift-outside-the-core tier, `just apps` and `just new-check` from clean, the device rows | see Gates |

## Deviations from the brief

- **No `KajoPin`; the pin is the checkout's prebuilt package.** SwiftPM
  refuses an absolute `binaryTarget` path ("path expected to be relative to
  package root"), and a relative one would tie the project to where it
  sits. A `KajoPin` with Swift sources over a prebuilt package (tried
  first) builds those sources for every architecture of a Mac Release
  build ("Any Mac": arm64 and x86_64), which the arm64-only frameworks
  cannot serve; package targets ignore the project's `ARCHS`. With no
  Swift compiled from any package, the app target's `ARCHS: arm64` holds.
  So the checkout carries `Prebuilt/Package.swift` with the binary targets
  and the project names it as its one local package.
- **Four xcframeworks, not one `Kajo.xcframework`**, and KajoCompiler and
  KajoShellCore are not prebuilt (part 2 above).
- **The CLI is `Contents/Helpers/kajo`**, not `Contents/MacOS/kajo`
  (case-insensitive names); **xcodegen ships in the app** (the brief did
  not name how a project file is made without Homebrew).
- **The checkout is inside the app**, linked from beside it in the dmg.
- **`xcodebuild build`, not `archive`**, for the slices (static frameworks
  are not archived).
- **The dmg carries only the development image**; the measurement modes'
  images are the repository build's.
- **`Config.swift` keeps its `!KajoAppBuild`** (no core change allowed); the
  trait is gone from the package.
- **The Kajo app's directory stays `apps/KajoShell-macOS`**; the target,
  scheme and product are `Kajo`.
- `just release` is now `just release-build`; `just release <tag>` is the
  release.

## Not done

- Developer ID signing, notarization, stapling and an accepting `spctl`
  (the owner's certificate and `notarytool store-credentials` profile);
  done on 2026-11-09, "The release of v0.1" below.
- A build with the network physically off (not allowed to touch it).
- `kajo-bench` on the phone (the kernels' files are on the Mac), and the
  Debug-against-Release check there; both iOS configurations link the
  same `ios-arm64` slice.
- Simulator slices, Intel, Sparkle (the questions below).
- The measurement modes in a dmg build find no images (`mode=` there is
  for the repository's build).
- `Config.swift`'s dead `!KajoAppBuild` (a one-line core change).

## Open questions for the owner (built as recommended; answered by the owner on 2026-11-09: 1 add the simulator slices, a follow-up in `docs/modules/simulator-slices.md`; 2 to 6 as built)

1. **Simulator slices**: none (the phone is the target; a simulator slice
   doubles the frameworks step and the size). Built: none.
2. **The command line tool**: a File menu item that links on request, with
   the `sudo` command shown when `/usr/local/bin` is not writable (on a
   fresh Apple silicon Mac it is root's or absent), against a `PATH` note
   in the README. Built: the item, and the README names the bundled path.
3. **An update mechanism**: none; the next dmg, with the versioned
   Application Support folders side by side (tested: 0.3 and 0.4 beside
   each other). Sparkle later if wanted.
4. **Sealing the Kajo app's own image**: no; the tools' write-back goes to
   the copied checkout's `tools/`. Built so.
5. (New) **xcodegen in the app** (7.3 MB, MIT) against writing the Xcode
   project file from the generator itself. Built: xcodegen bundled.
6. (New) **The prebuilt pin's form**: the checkout's `Prebuilt/` package
   by absolute path (above). A project moved to another Mac needs the same
   Kajo version there; a later public form would be a remote binary
   package (a URL and a checksum per framework).

## Commands

```
scripts/dist.sh <version>                    # Kajo-<version>.dmg, .build/dist/<version>/
scripts/dist.sh checkout <dir>               # the working tree's checkout with Prebuilt/
scripts/release.sh v0.<n> [--dry-run]        # tag, dist, the gh command
KAJO_SIGN_IDENTITY, KAJO_NOTARY_PROFILE, KAJO_DIST_OUT, KAJO_DIST_WORKTREE=1
Kajo.app/Contents/MacOS/Kajo [newapp=<Name> bundle=<id> into=<dir>] [cli-install=1]
  (KAJO_SUPPORT_DIR, KAJO_CLI_LINK_DIR, KAJO_OPEN_XCODE=0, KAJO_CHECKOUT)
<App>.app/Contents/MacOS/<App> kajo-bench=<kernels>/fib.kasm [kajo-bench-runs=N]
APP_PROJECT=<dir> KAJO=<kajo> scripts/app-roundtrip.sh mac|device <out>
APP_PROJECT=<dir> KAJO_CHECKOUT=<checkout> KAJO_NEW=<kajo> scripts/new-check.sh <out>
```

For a real release once the owner has a Developer ID Application
certificate in the login keychain and a profile from `xcrun notarytool
store-credentials kajo-notary ...`:

```
KAJO_NOTARY_PROFILE=kajo-notary scripts/release.sh v0.1
git push origin v0.1
gh release create v0.1 .build/dist/0.1/Kajo-0.1.dmg .build/dist/0.1/Kajo-0.1.dmg.sha256 --title 'Kajo 0.1' --notes-file .build/dist/0.1/notes.md --verify-tag
```

## The release of v0.1 (2026-11-09)

With the owner's `Developer ID Application: Joni Katajamaki (BDN6M642M2)`
certificate in the login keychain and the `kajo-notary` profile,
`KAJO_NOTARY_PROFILE=kajo-notary just release v0.1` ran on 8b11e25 with
the script as built: export 1 s, CLI 51 s, frameworks 72 s (macOS and
iOS, 0 warnings), app 53 s, signing 9 s with `codesign --verify --deep
--strict` ok, notarizing the app 36 s, the dmg 5 s, notarizing the dmg
34 s, the checks 11 s; 4 min 32 s in all. `spctl` accepts the app, the
dmg and a quarantined copy of the dmg and the app inside it, every one
`source=Notarized Developer ID`, and the bundled `kajo test` passes 211
of 211. `Kajo-0.1.dmg` is 15 431 768 bytes (SHA-256
`e8834521384d1840bad36b0d55e85da5da01269f903da12f1d5d0c95c72052ba`);
the app 45.0 MiB, of which the checkout 25.1 MiB (`Prebuilt/` 18.0,
KajoVM 10.1), xcodegen 7.2 MiB, `dev.img` 6.2 MB. The tag `v0.1` is
pushed.

Two attempts the day before did not finish: the first's `xcodebuild` for
the app was SIGKILLed at 0 s (exit 137, nothing in the system log named
a killer; the retry built it in 50 s), and the second's `codesign` with
the Developer ID identity waited on the keychain's access prompt, which
`dist.sh`'s 120 s bound turned into a `FAILED codesign` line (the prompt
is the owner's; "A gate that waits on a prompt is a blocked gate"). The
local tag was removed and the release retagged at the day's head once
the owner had allowed the access.

## Gates

`just check` on 1667cb1, the last commit that changes code (tier "Swift
outside the core", chosen by 29 of the 32 files, no fuzzer: nothing under
`Sources/KajoDev`, `Sources/KajoCompiler` or the fuzz targets changed),
2026-11-08 07:45 to 08:49, swift.org 6.4.2 first on PATH, Xcode 27.2 for the
apps; outputs in the session's `distribution/gates/`. A first run on 8523a77
stopped at `just apps`: the iOS shell did not build, because KajoShellCore
now depends on KajoGenerator and its `Process` call does not exist on iOS
(1667cb1 puts it behind `#if os(macOS)`; that run's outputs are in
`gates-first-8523a77/`). The device rows ran before the gates (above).

| gate | result |
|---|---|
| clean-build | exit 0, 0 warnings, 0 errors, 22 s (the compilation cache; the strict-memory-safety compile from nothing is in `just apps`, `just new-check` and `dist.sh`'s frameworks, all 0 warnings) |
| swift-test | 385 + 121 passed, 308 + 95 s |
| tsan (alone) | 385 + 121 passed, 0 ThreadSanitizer reports, 704 + 2320 s |
| kernel-test | 205 of 205 |
| apps | macOS (the Kajo app) and iOS: exit 0, 0 errors, 0 warnings |
| new-check | ok: the working tree's checkout with its Prebuilt/ in 117 s; four builds from clean, 0 errors, 0 warnings each (Mac Debug 7 s, Release 5 s; iOS Debug 5 s, Release 4 s); Release binaries 1 961 040 B (Mac) and 1 829 896 B (iOS) with 0 symbols of KajoDev, KajoAppDevelopment, KajoCompiler and KajoShellCore, no Bonjour string or import, no local-network key, a release image that refuses to serve; Debug with all of them; no Kajo module compiled for the app, 5559 prebuilt KajoVM symbols in the Debug product |

`gates.log`:

```
2026-11-08 07:44:59 1667cb1 check-tier swift: 32 files from origin/master...HEAD (b008d35...1667cb1) and the working tree
2026-11-08 07:44:59 1667cb1 start clean-build (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 07:45:21 1667cb1 end clean-build rc=0 22s
2026-11-08 07:45:21 1667cb1 start swift-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 07:52:10 1667cb1 end swift-test rc=0 409s
2026-11-08 07:52:10 1667cb1 start tsan (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 08:42:50 1667cb1 end tsan rc=0 3040s
2026-11-08 08:42:50 1667cb1 start kernel-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 08:44:06 1667cb1 end kernel-test rc=0 76s
2026-11-08 08:44:06 1667cb1 start apps (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 08:45:59 1667cb1 end apps rc=0 113s
2026-11-08 08:45:59 1667cb1 start new-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 08:49:02 1667cb1 end new-check rc=0 183s
2026-11-08 08:49:02 1667cb1 check-tier done swift failed=0 3843s
```

