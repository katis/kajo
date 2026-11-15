# Module 11a: the app project

Module 11a (the app project, built 2026-11-06,
`docs/modules/app-project.md`, ADR 0014 proposed): the AppKit and UIKit
hosts and the runtime are the `KajoApp` library and serving, the token store
and the pairing screens the `KajoAppDevelopment` library, the shells in
`apps/` rebuilt on them (54 and 64 lines of Swift of their own); `kajo new`
(the `KajoGenerator` library, deterministic, every refusal a value, its
output a byte-for-byte fixture) writes an xcodegen project with a Mac and an
iOS target over one `src/` of Tonel, one 17-line `App.swift`, a build phase
making a development image in Debug and a sealed one in Release, and a local
`KajoPin` package that pins Kajo and enables the `KajoAppBuild` trait; a
Debug build serves over TCP and Bonjour from launch as "<app> on <device>"
with 9d's per-install token, the pairing screen a shake on iOS and the app
menu's Pairing… on the Mac; a Release binary has 0 symbols of KajoDev,
KajoAppDevelopment, KajoCompiler and KajoShellCore, no Bonjour import and no
local-network key (2.1 MB on the Mac, 2.0 on iOS), checked by `just
new-check` on every run; because Xcode links a package product in every
configuration the development half is a dependency with `link: false` and
Debug's linker flags name its three prelinked objects; on the Mac the round
trip ran whole (generate, build, connect by Bonjour name, change a method
live in 68 to 70 ms from the CLI and 5 to 8 ms from the tools, the change in
`src/`, rebuilt and there at launch, the Release app not serving), 0 of 3780
frames missed across 8 sessions and 2 changes, cold launch 213 to 255 ms
Debug and 190 to 235 Release, the Debug VM 2.6 to 4.0 times slower than
Release, bench within noise and `interpret` identical; a latent 9a trap
fixed (a follow-up turn outliving its host); the refactored shells pass 202
of 202 and miss 0 of 1200 frames in every scenario on both devices; the
sample app's device rows did not run: `xcodebuild` answers "No Accounts" for
the new bundle identifier `dev.katajamaki.kajo.sample` (the account the
owner signed in that morning is no longer seen; the main session's own
attempt got the same answer; the owner signed Xcode in again and built the
sample from Xcode's window on 2026-11-07, after which its profile exists),
and its six open questions answered by the owner on 2026-11-07: the Release
VM ships as a prebuilt xcframework in the dmg so development builds run it,
generated projects pin a checkout the dmg carries (copied to
`~/Library/Application Support/Kajo/<version>/`; the public repository with
tags later), the paid Developer Program is renewed so Developer ID signing
and notarization are available, pairing via shake and ⇧⌘P, object-name
linking and the Mac sandbox off stay as built; the sample's device rows ran
on 2026-11-07, `docs/modules/app-project.md`: the CLI changes a method live
on the phone in 140 ms and on the iPad in 174 ms, the Release app does not
serve, and three things were found for a follow-up: the generated iOS plist
lacks `CADisableMinimumFrameDurationOnPhone` so the sample runs at 60 Hz on
the iPhone, the Debug build takes 35 s to its first frame on both devices
where Release takes 0.1 to 0.2 s, and `app-roundtrip.sh`'s by-address
fallback keeps the first launch's port; all three fixed the same day,
`docs/modules/app-project.md` "The sample on the devices": the key is in
both generated iOS plists and the fixture, the 35 s was
`ProcessInfo.hostName` on the main thread answering "localhost" after 35.0 s
in every traced launch, found by a launch trace (`kajo-launch-report` prints
`launch step=<name> ms=` per step) and not by the suspects the brief named,
so the device's part of the service name is the model's on iOS and the
development half starts at the app's second frame or after 1 s without
frames (`AfterFrames`, `KajoAppRunner.startDevelopment`, told once), the
script re-reads the address and port from the console of the launch it talks
to and a rebuilt app that does not answer is a `FAILED` line; after: the
iPhone's Debug first frame 103 to 157 ms and the iPad's 230 to 254 against
35.2 to 35.6 s, 120 Hz on the iPhone with 0 of 1264, 3647 and 1012 frames
missed, `starts_with_change=1` on both devices by address, the Mac
unchanged; the owner allowed Local Network for the sample on both devices
the same evening and the round trip then ran by name on each (`Sample on
iPhone`, `Sample on iPad`, `starts_with_change=1`, 0 frames missed, the
first request paying the name's resolution: 143 ms on the iPhone and 899 on
the iPad); gates of the Swift-outside-core tier on 6ffdb6d, 381 + 115 tests,
ThreadSanitizer 0 reports, 205 kernel tests, the protocol fuzzer 366 718
runs.
