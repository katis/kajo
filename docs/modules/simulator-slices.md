# Simulator slices in the prebuilt frameworks (a follow-up of module 11b)

Status: built 2026-11-09 ("As built" below the brief).

The owner's answer of 2026-11-09 to Distribution's first question: the
prebuilt xcframeworks (`Prebuilt/{KajoVM,KajoApp,KajoDev,KajoAppDevelopment}.xcframework`,
built by `scripts/dist.sh` from `scripts/dist-frameworks.yml`) carry a
macOS arm64 and an iOS arm64 slice, so a generated app's iOS target cannot
run in the iOS Simulator. Add an iOS Simulator arm64 slice to each.

## What to build

1. `scripts/dist-frameworks.yml` and `scripts/dist.sh`: a third
   `xcodebuild build` destination (`generic/platform=iOS Simulator`,
   `ARCHS=arm64` only; every Mac Kajo runs on is Apple silicon), a third
   `-framework` in `-create-xcframework`, `SUPPORTED_PLATFORMS` including
   `iphonesimulator`, the manifest and the size listing naming the slice.
   The macOS and iOS slices stay as they are, bit for bit the same
   flags.
2. The generated project (`Sources/KajoGenerator`, its fixture): whatever
   it needs so its iOS target builds and runs for a simulator destination
   in both configurations with no change to the device build. If it needs
   nothing, say so and show the build.
3. `scripts/new-check.sh`: one more build of the generated app's Debug iOS
   target for `generic/platform=iOS Simulator` from the dmg-made
   checkout, 0 warnings or fail, and the generated Release iOS binary's
   checks unchanged.
4. `docs/modules/distribution.md`: the slice named where the frameworks
   are described, the size table re-measured.

## Bar

- `scripts/dist.sh 0.2-dev` (a local version number, no tag, no
  notarization) builds every framework with the third slice; `xcodebuild
  -create-xcframework` succeeds; each xcframework's `Info.plist` lists
  three library identifiers.
- A dmg-made generated app builds for `generic/platform=iOS Simulator`
  in Debug and Release with 0 warnings, and the Debug app launches in a
  booted iPhone simulator (`xcrun simctl`) to its first frame and serves
  (the Bonjour name appears in `dns-sd -B _kajo-dev._tcp` or the console
  prints the port); the Release app launches and does not serve.
- The device build of the same generated app is unchanged: `just
  new-check` passes as before plus the new simulator build.
- The frameworks step's time and the dmg's size before and after, in the
  doc (the brief expects about +10 MB).
- Nothing under `Sources/KajoVM`, `kernel/` or `tools/`; `just check` on
  the final code commit (the Swift tier if the generator changed, the
  scripts-only case runs the Swift tier too since `new-check.sh` is a
  gate's own script: say which it picked).

## Open questions for the owner (build the recommended option, list them)

1. Should the simulator slice also carry x86_64 for Intel Macs running
   the simulator? Recommended: no, arm64 only (no Intel build anywhere in
   Kajo; the Mac app itself is arm64 only).
2. Should `kajo new`'s round trip (`app-roundtrip.sh`) gain a `simulator`
   target beside `mac` and `device`? Recommended: not now; the bar's
   launch and serve check is enough, the round trip is for the devices.

## As built

Built 2026-11-09 on the Mac mini (M2 Pro, macOS 27.2, Xcode 27.2, swift.org
6.4.2 first on PATH). Code commits 124793d (the scripts) and 8f06c70 (the
generator, its fixture and its test). Nothing under `Sources/KajoVM`,
`kernel/` or `tools/` changed. Every `dist.sh` run used version `0.2`
(below), `KAJO_DIST_OUT` in the session's scratchpad and the Apple
Development identity (`KAJO_SIGN_IDENTITY`), no tag and no notarization;
`.build/dist/0.1/` was not touched. Outputs are in the session's
`simslices/` (`dist/`, `simbuild/`, `newcheck/`, `check/`).

### What changed

- **`scripts/dist-frameworks.yml`**: `SUPPORTED_PLATFORMS` is `macosx
  iphoneos iphonesimulator`; nothing else (the targets'
  `supportedDestinations: [macOS, iOS]` already cover the simulator SDK).
- **`scripts/dist.sh`**: `build_frameworks` runs one `xcodebuild build` per
  slice from a list of three, `macOS`, `iOS` and `iOSSimulator`
  (destination `generic/platform=iOS Simulator`, `ARCHS=arm64
  ONLY_ACTIVE_ARCH=NO` as the other two, products in
  `Release-iphonesimulator`, log `fw-iOSSimulator.log`); the flags manifest
  (`FLAGS.txt`) reads the third slice's compile lines;
  `-create-xcframework` takes the three `-framework`s from the same list;
  `Prebuilt/Package.swift`'s comment and the size listing name
  `ios-arm64-simulator`. The macOS and iOS builds are the same commands as
  before.
- **The generator** (`Sources/KajoGenerator/Templates.swift`, the fixture's
  `project.yml`, `AppProjectTests`): the iOS target gains
  `"ARCHS[sdk=iphonesimulator*]": arm64`. It was needed: the first
  simulator build of a generated project failed with "Unable to resolve
  module dependency: 'KajoApp'" because a generic simulator build asks for
  `arm64 x86_64` and the slice has only arm64
  (`simbuild/first-attempt/`). The setting is scoped to the simulator SDK,
  so the device build is unchanged (`xcodebuild -showBuildSettings`:
  `iphoneos` ARCHS `arm64` with and without it, `iphonesimulator` `arm64
  x86_64` without it and `arm64` with it; `simbuild/archs-per-sdk.txt`).
  The test that a macOS-less project has no `ARCHS: arm64` now also
  expects the simulator line.
- **`scripts/new-check.sh`**: after the iOS Debug device build, one more
  build of the iOS target's Debug for `generic/platform=iOS Simulator`
  (`CODE_SIGNING_ALLOWED=NO` as the device builds), 0 errors and 0
  warnings or fail, then the Debug product's checks on
  `Sample.debug.dylib` (development symbols, strings, plist keys, an image
  that serves) and `vtool -show-build` saying `IOSSIMULATOR`. The Release
  iOS device build and its checks are as before.
- `scripts/app-roundtrip.sh`: unchanged (question 2).

### The slices

`KajoVM.xcframework/Info.plist` from the final dmg (`dist/KajoVM.xcframework-Info.plist`):

| LibraryIdentifier | SupportedPlatform | SupportedPlatformVariant | SupportedArchitectures |
|---|---|---|---|
| `ios-arm64` | ios | | arm64 |
| `ios-arm64-simulator` | ios | simulator | arm64 |
| `macos-arm64` | macos | | arm64 |

The other three xcframeworks list the same three identifiers. The third
slice's compile lines (`FLAGS.txt`) are the other two's with the
simulator target, for all four modules:

```
iOSSimulator KajoVM: -O -whole-module-optimization -strict-memory-safety -target arm64-apple-ios18.0-simulator -enable-library-evolution -swift-version 6
```

0 errors and 0 warnings on all three platforms. The macOS and iOS slices
are the same code as before: the binaries have the same sizes, and their
object files disassemble identically (`otool -tV`) for KajoVM, KajoApp
and KajoAppDevelopment; KajoDev's differ in two `mov` immediates, the
length of a source path string (`dist-before` against `dist-after` in the
two runs' output directories).

### Time and size

`scripts/dist.sh 0.2` on 5e3a54e (the script before, from a temporary
worktree) and on 8f06c70 (`dist/dist-before.log`, `dist/dist-final.log`):

| | before | after |
|---|--:|--:|
| frameworks step | 69 s (macOS 34, iOS 32) | 100 s (macOS 34, iOS 32, simulator 31); a first run on 124793d 109 s |
| dmg (UDZO, HFS+) | 15 448 949 B | 17 452 775 B (+2 003 826, +13 %) |
| Kajo.app | 46 544 KiB | 54 356 KiB (+7 812) |
| `Prebuilt/` | 18 932 KiB | 26 728 KiB (+7 796) |
| KajoVM.xcframework | 10 812 KiB | 16 172 KiB (simulator binary 3 349 600 B) |
| KajoDev.xcframework | 2 580 KiB | 3 856 KiB (760 920 B) |
| KajoApp.xcframework | 1 692 KiB | 2 428 KiB (424 616 B) |
| KajoAppDevelopment.xcframework | 892 KiB | 1 316 KiB (266 112 B) |

The brief expected about +10 MB; the app grows by 7.6 MiB and the
compressed dmg by 2.0 MB (each slice's module interfaces and
swiftmodules are about as large as its binary). The whole run took 3 min
39 s against 3 min 9 s. The bundled `kajo test` passed 211 of 211.

(The brief named version `0.2-dev`; `dist.sh` refuses it, since a version
is numbers and dots and becomes the app's `CFBundleShortVersionString`,
so the runs used `0.2` with the output in the scratchpad. A deviation of
the run, not of the script.)

### The simulator builds and the launch

From the final dmg: its checkout copied out of the app, `Sample` made by
the dmg's own `kajo new`, then `xcodebuild -scheme Sample-iOS
-destination 'generic/platform=iOS Simulator'` with signing as generated
(`simbuild/`):

| configuration | result | product |
|---|---|---|
| Debug | exit 0, 0 errors, 0 warnings, 6 s | `Sample.debug.dylib` 2 339 360 B, IOSSIMULATOR arm64, app 7 596 KiB, ad hoc signed |
| Release | exit 0, 0 errors, 0 warnings, 5 s | `Sample` 1 859 552 B, IOSSIMULATOR arm64, app 7 060 KiB, ad hoc signed |

The four xcframeworks were processed for "ios simulator" and no Kajo
module was compiled. (The one `warning:` line in each log is
`appintentsmetadataprocessor`'s "Metadata extraction skipped", a tool's
note, not a compiler warning, as in the device builds.)

**Launch and serve** (`simbuild/launch/summary.txt`): the owner installed
the iOS 27.2 simulator runtime during the run. A temporary device
(`kajo-simslices-temp`, iPhone 17, iOS 27.2) booted in 25 s; each build
installed with `simctl install` and launched three times with `simctl
launch --console-pty ... kajo-launch-report` under a 15 s bound:

| | first frame (ms) | serving |
|---|---|---|
| Debug | 477.1, 419.3, 459.6 | `serving=tcp port=<new each launch> ... name=Sample_on_kajo-simslices-temp` every launch; `dns-sd -B _kajo-dev._tcp` lists "Sample on kajo-simslices-temp"; one listening socket on the Mac |
| Release | 397.5, 374.1, 363.9 | no serving line in any launch, nothing in `dns-sd -B`, no listening socket |

The device was shut down and deleted. The same launches of the project as
hand-edited before the generator commit (the same `project.yml` but for
one comment line) on an earlier temporary device gave Debug 376 to 384 ms
and Release 352 to 385 ms with the same serving results
(`simbuild/hand-edited/`).

### `just new-check`

From the final dmg's checkout and its `kajo` (`newcheck/new-check-dmg-checkout.txt`):
`new-check: ok`, the five builds 0 errors and 0 warnings each; the new row

```
ios-simulator-debug: exit=0 errors=0 warnings=0 seconds=4
ios-simulator-debug: binary_bytes=2352848 image_bytes=5266872 KajoDev=1171 KajoAppDevelopment=339 KajoCompiler=0 KajoShellCore=0 _kajo-dev._tcp=1 kajo-pairing-token=1 DNSServiceRegister=1 plist_keys=2 image_refuses_to_serve=0
ios-simulator-debug: platform=IOSSIMULATOR
```

and the Release rows as before (iOS 1 872 056 B, Mac 1 986 944 B, 0
development symbols, no Bonjour string or import, no local-network key,
an image that refuses to serve). The gate's own run on the working tree
is in Gates.

### The bar

| item | result |
|---|---|
| `dist.sh 0.2-dev` builds every framework with the third slice; `-create-xcframework` succeeds; three identifiers each | met (as `0.2`, see above) |
| the dmg-made app builds for the simulator in Debug and Release with 0 warnings | met, after the generator's simulator ARCHS |
| the Debug app launches in a booted simulator to its first frame and serves; Release launches and does not serve | met |
| the device build unchanged; `just new-check` passes plus the simulator build | met |
| the frameworks step's time and the dmg's size before and after | above: 69 to 100 s, 15.4 to 17.5 MB |
| nothing under `Sources/KajoVM`, `kernel/`, `tools/`; `just check` on the final code commit | met; Gates |

### Gates

`just check` on 8f06c70, the last code commit, 2026-11-09 07:22 to 08:21,
swift.org 6.4.2 first on PATH, Xcode 27.2 for the apps: tier "Swift
outside the core", chosen by all 6 files (the generator, its test and
fixture, and three scripts; `new-check.sh` is a gate's own script), no
fuzzer owed (nothing under `Sources/KajoDev`, `Sources/KajoCompiler` or
the fuzz targets). Every gate passed in 3522 s:

| gate | result |
|---|---|
| clean-build | exit 0, 0 warnings, 22 s |
| swift-test | 394 + 121 passed, 391 s |
| tsan (alone) | 394 + 121 passed, 0 ThreadSanitizer reports, 2686 s |
| kernel-test | 211 of 211 |
| apps | macOS (the Kajo app) and iOS: exit 0, 0 errors, 0 warnings |
| new-check | ok: the working tree's checkout with its three-slice `Prebuilt/` in 147 s; six builds from clean with 0 errors and 0 warnings, the new `ios-simulator-debug` row a simulator binary with the Debug checks, the Release rows unchanged |

`gates.log`:

```
2026-11-09 07:22:43 8f06c70 check-tier swift: 6 files from origin/master...HEAD (5e3a54e...8f06c70) and the working tree
2026-11-09 07:22:43 8f06c70 start clean-build (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 07:23:05 8f06c70 end clean-build rc=0 22s
2026-11-09 07:23:05 8f06c70 start swift-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 07:29:36 8f06c70 end swift-test rc=0 391s
2026-11-09 07:29:36 8f06c70 start tsan (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 08:14:22 8f06c70 end tsan rc=0 2686s
2026-11-09 08:14:22 8f06c70 start kernel-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 08:15:34 8f06c70 end kernel-test rc=0 72s
2026-11-09 08:15:34 8f06c70 start apps (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 08:17:27 8f06c70 end apps rc=0 113s
2026-11-09 08:17:27 8f06c70 start new-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 08:21:25 8f06c70 end new-check rc=0 238s
2026-11-09 08:21:25 8f06c70 check-tier done swift failed=0 3522s
```

### Deviations

- The generator changed (the brief allowed it: part 2 "whatever it
  needs"): one SDK-conditional `ARCHS` line in the iOS target.
- The runs used version `0.2`, not `0.2-dev` (the script's version rule).
- The "before" numbers come from the unchanged script run from a
  temporary `git worktree` of 5e3a54e (removed afterwards), not from the
  v0.1 release, whose dmg is notarized and stapled.

### Not done

- x86_64 simulator slices (question 1).
- A `simulator` target in `app-roundtrip.sh` (question 2); the launch
  check above was run by hand with `simctl`.
- No request was sent to the simulator's server (no token was read); the
  serving line, the Bonjour name and the listening socket are the bar's
  evidence.

### Open questions for the owner (built as recommended)

1. An x86_64 slice for Intel Macs running the simulator? Built: arm64
   only, and the generated iOS target asks for arm64 only in the
   simulator.
2. A `simulator` target in `app-roundtrip.sh`? Built: not now.
