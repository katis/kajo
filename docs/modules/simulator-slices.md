# Simulator slices in the prebuilt frameworks (a follow-up of module 11b)

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
