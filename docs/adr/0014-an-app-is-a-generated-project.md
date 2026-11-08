# ADR 0014: A Kajo app is a generated Xcode project over the Kajo package, serving by build configuration

Date: 2026-11-06
Status: proposed (module 11a, `docs/modules/app-project.md`; amended by
module 11b, `docs/modules/distribution.md`: the pin is a distribution
checkout's prebuilt Kajo, and the trait is gone)

## Context

The owner's distribution shape (2026-11-05): Kajo ships as one Mac app
carrying the development image; a developer's own app is a generated
project with a Mac and an iOS target over one Tonel directory, depending
on the Kajo package; the phone runs the developer's own development build
installed with Xcode, so no Kajo app is ever reviewed under guideline
2.5.2, and serving the development protocol is a property of that build.
Until module 11a the AppKit and UIKit hosts lived in the shells' app
targets, serving was a launch argument of the shells, and nothing could
make a project.

## Decision

- **The hosts are library code.** `KajoApp` (one product, an AppKit half
  and a UIKit half compiled for their platform) holds the runtime, the
  view hosts (`AppKitHost`, `UIKitHost`) and the entry a generated app
  calls (`KajoApplication.main`). `KajoAppDevelopment` holds serving
  (TCP, Bonjour, the per-install token), the pairing screens and the
  development half `Development`. The shells in `apps/` are rebuilt on
  both; their measurement modes stay in `KajoShellCore`, which no app
  links.
- **`kajo new` writes the project**, a library function first
  (`KajoGenerator`), deterministic, refusing bad input with a value. The
  project is an xcodegen spec, one or two targets over `src/`, one local
  package (since 11b: the `Prebuilt/` package of a distribution checkout,
  which the Kajo app copies to `~/Library/Application Support/Kajo/<version>/`),
  one Swift file of a dozen lines, per-configuration Info.plists and an
  image build phase that runs the checkout's prebuilt `kajo`.
- **Debug is the development build, Release the release build.** Debug
  bundles a development image and links `Development`, which serves from
  launch over TCP with a Bonjour name "<app> on <device>" and the
  per-install token; its pairing screen is a shake on iOS and the app
  menu's Pairing item on the Mac. Release bundles a sealed image, links
  none of `KajoAppDevelopment`, `KajoDev`, `KajoCompiler` or
  `KajoShellCore`, and its Info.plist names neither the Bonjour service
  nor the local network. Two locks: the binary has no transport, and the
  image refuses to serve.
- **Per-configuration linking is done by the linker, not by Xcode's
  package product.** Xcode links a package product in every configuration
  and dead stripping keeps most of an unreferenced Swift module (its
  metadata records are live), so the development product is a dependency
  with `link: false` and Debug's `OTHER_LDFLAGS` names it. Since 11b it
  names the prebuilt static frameworks (`-framework KajoAppDevelopment
  -framework KajoDev`), names Kajo owns; 11a named the objects Xcode
  prelinks for package targets (`KajoPinDevelopment.o` and two more).
  `just new-check` checks the built binaries every run.
- **An app's Debug build runs the Release VM.** Since 11b both
  configurations link the same prebuilt Release frameworks (`-O`, whole
  module, strict memory safety, library evolution), built by
  `scripts/dist.sh`; no Kajo module is compiled for an app. (11a's Debug
  VM was Xcode's Debug build of the package made optimized by a package
  trait, `KajoAppBuild`, file by file and 2.6 to 4.0 times slower than
  Release; the trait and the local `KajoPin` package that set it are gone.)

## Consequences

- One implementation of every wrapper: the shells' tests and matrix test
  the code apps run.
- A development build is as fast to start developing as `xcodebuild`;
  nothing on the device needs a launch argument.
- The Debug VM is the Release VM (11b; 11a's was 2.6 to 4.0 times slower).
- The `OTHER_LDFLAGS` frameworks and `link: false` are the places an Xcode
  release can break the shape; `just new-check` checks the binaries.
- A project pins a checkout on the developer's Mac by absolute path; the
  public repository with tags is a later form (the owner, 2026-11-07).
- The prebuilt frameworks are Apple silicon only on the Mac, so a
  generated Mac target builds arm64 only.

## Evidence

`docs/modules/app-project.md` (Measurements, Gates). On the Mac mini: a
Release binary of 2.1 MB (Mac) and 2.0 MB (iOS) with no symbol of the
development half against 5.4 and 5.0 MB Debug; a change landed in the
running Debug app 68 to 70 ms after the compile request from the CLI and
in 5 to 6 ms per step from the tools, with 0 of 3780 frames missed over
the window; cold launch to the first frame 213 to 255 ms Debug and 190
to 235 ms Release. The device rows of the round trip wait for the
owner's signing account.
