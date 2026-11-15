# The simulator slices

The simulator slices, built 2026-11-09 (`docs/modules/simulator-slices.md`,
the first answer built; scripts and the generator, nothing under
`Sources/KajoVM`, `kernel/` or `tools/`): `dist.sh` builds a third slice of
each prebuilt framework for `generic/platform=iOS Simulator` at
`ARCHS=arm64` with the same flags (`-target arm64-apple-ios18.0-simulator`),
`-create-xcframework` takes the three, each xcframework lists `ios-arm64`,
`ios-arm64-simulator` and `macos-arm64`, the manifest and the size listing
name the slice; the generated iOS target gains
`"ARCHS[sdk=iphonesimulator*]": arm64` because a generic simulator build
asks for x86_64 too and failed to resolve `KajoApp` (the device build's
settings unchanged, shown by `-showBuildSettings`; fixture and test in the
same commit); `new-check.sh` builds the generated iOS target's Debug for the
simulator with 0 warnings, the Debug product's checks and `vtool` saying
`IOSSIMULATOR`; measured: the frameworks step 69 to 100 s, the dmg 15 448
949 to 17 452 775 bytes (+2.0 MB; the app +7.6 MiB, each slice's interfaces
about as large as its binary), the macOS and iOS slices' object code
identical but for two path-length immediates; a dmg-made Sample builds for
the simulator in Debug (6 s) and Release (5 s) with 0 warnings and no Kajo
module compiled, and on a temporary iPhone 17 simulator (iOS 27.2, the
runtime installed by the owner during the run) the Debug app reaches its
first frame in 419 to 477 ms and serves (a `serving=tcp` line each launch,
the name in `dns-sd -B`, one listening socket) while the Release app reaches
it in 364 to 398 ms and does not; `just check` on 8f06c70, the Swift tier,
every gate in 3522 s (394 + 121 tests, ThreadSanitizer 0 reports, 211 kernel
tests, apps, new-check with the simulator row); not done: no x86_64 slice,
no `simulator` target in `app-roundtrip.sh`, no request sent to the
simulator's server (needs the token); its two questions built as recommended
(arm64 only; no round-trip target).
