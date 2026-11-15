# Module 11b: Distribution and the first release

Module 11b, Distribution, built 2026-11-08 (`docs/modules/distribution.md`,
ADR 0014 amended; nothing under `Sources/KajoVM`, `kernel/` or `tools/`):
the macOS shell is the Kajo app (target, scheme and product `Kajo`, bundle
`dev.katajamaki.kajo`, `Sources/KajoShellCore/Product.swift`: with no
`mode=` it copies the checkout it carries to `~/Library/Application
Support/Kajo/<version>/` once per version, a partial folder renamed with a
marker written last and an incomplete one moved aside, opens the tools on
the development image with write-back to the copied `tools/`, File > New
App… over `KajoGenerator` and a bundled xcodegen, File > Install Command
Line Tool… linking `Contents/Helpers/kajo` into `/usr/local/bin` on request
and showing the `sudo ln` line when it cannot write there;
`KAJO_SUPPORT_DIR` and `KAJO_CLI_LINK_DIR` override both for tests); the
checkout's `Prebuilt/` holds four static xcframeworks (KajoVM, KajoApp,
KajoAppDevelopment, KajoDev; macOS arm64 and iOS arm64 slices, every compile
`-O -whole-module-optimization -strict-memory-safety
-enable-library-evolution -swift-version 6`, no `-g`, no `-enable-testing`,
built by `xcodebuild build` from `scripts/dist-frameworks.yml`), `bin/kajo`
and a `Package.swift` of binary targets that a generated project names as
its one local package (SwiftPM refuses an absolute `binaryTarget` path and a
`KajoPin` with Swift sources is compiled for x86_64 too in an Any Mac
Release build, so `KajoPin`, the `KajoAppBuild` trait and KajoVM's
conditional `-O` are gone; both configurations link `KajoApp`, Debug adds
the development frameworks by name with `link: false`, the image phase runs
the prebuilt `kajo` and compiles nothing: 0.12 s where 11a's took 14);
`scripts/dist.sh <version>` (export, CLI, frameworks, app, inside-out
signing with the hardened runtime and no entitlements, notarization and
stapling only when `KAJO_NOTARY_PROFILE` names a keychain profile, `hdiutil`
dmg with SHA-256, `codesign --verify` and `spctl` on the app, the dmg and a
quarantined copy; 3 min 7 s) and `scripts/release.sh v0.<n> [--dry-run]`
(local tag, dist, notes, the `git push` and `gh release create` lines,
uploads nothing); measured from the dmg-made Sample: the Debug app's VM at
1.005 of Release on fib, 0.997 sends, 0.999 alloc (n = 9 each, checksums
equal; 11a's 2.6 to 4.0), Debug first frame 188 to 232 ms on the Mac, 99 to
114 on the iPhone, 224 to 241 on the iPad, 0 frames missed in every window
but one Mac live window (1 of 3786), builds from clean 5 to 9 s against 30
to 43, the bundled `kajo test` 205 of 205, the round trip by Bonjour name on
the Mac twice, the iPad once and the iPhone on the third run (the first two
rebuilt steps found the name still resolving to the previous launch's port,
`Connection refused`, so `app-roundtrip.sh` falls back to the console's
address, 8523a77, a path no device run has exercised yet); sizes: dmg 15.3
MB, the app 45.8 MiB of which the checkout 25.7 MiB (`Prebuilt/` 18.6,
KajoVM 10.5), xcodegen 7.3 MiB, `dev.img` 6.1 MB; Gatekeeper not met: the
keychain holds only an Apple Development identity and no notary profile,
`spctl` rejects the app and the dmg (origin Apple Development), the dmg is
named `Kajo-0.1-unsigned-dev.dmg` and the script needs no change once a
Developer ID Application certificate and `notarytool store-credentials
kajo-notary` exist (the owner's); the offline build met with
`-skipPackageUpdates -disableAutomaticPackageResolution
-onlyUsePackageVersionsFromResolvedFile -scmProvider system`, empty caches
and a log that fetched nothing, the network itself on; `just check` on
1667cb1 (Swift tier, no fuzzer owed): 385 + 121 tests, ThreadSanitizer 0
reports in 3040 s, 205 kernel tests, apps, new-check on the wizard's
project, the first run on 8523a77 failing `just apps` because
`KajoShellCore` used `Process` on iOS (fixed in 1667cb1); the first real
release ran on 2026-11-09 once the owner had created the `Developer ID
Application: Joni Katajamaki (BDN6M642M2)` certificate and the `kajo-notary`
profile and allowed the keychain prompt (`KAJO_NOTARY_PROFILE=kajo-notary
just release v0.1` on 8b11e25: export, CLI, frameworks, app, signing,
notarizing the app in 36 s and the dmg in 34 s, stapling, `spctl` accepting
the app, the dmg and a quarantined copy as "Notarized Developer ID", the
bundled `kajo test` 211 of 211, 4 min 32 s in all; `Kajo-0.1.dmg` 15 431 768
bytes; the tag `v0.1` pushed; two earlier attempts the day before died on
the keychain prompt `codesign` waited on, which `dist.sh`'s 120 s bound
turned into a `FAILED` line, and one `xcodebuild` SIGKILLed at 0 s with no
killer in the log); not done: a build with the network off, `kajo-bench` on
the phone, simulator and Intel slices, Sparkle, `Config.swift`'s dead
`!KajoAppBuild`; its six open questions answered by the owner on 2026-11-09:
simulator slices are to be added to the prebuilt xcframeworks (a follow-up,
`docs/modules/simulator-slices.md`), the rest as built (the menu item for
the CLI, no updater, the app's image not sealed, xcodegen bundled at 7.3 MB,
the absolute pin now and a remote binary package with a later release).
