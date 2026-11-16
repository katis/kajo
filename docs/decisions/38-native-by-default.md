# Native code on by default in a Release build

A follow-up of AOT 2, built 2026-11-16 (`docs/modules/native-by-default.md`;
one sitting, final code commit 0f3c282, the doc's last commit acab457). The
owner's answer of 2026-11-15 to AOT 2's first question was "On by default";
this module built it and measured, first, what AOT 2 had left unmeasured.

## What was built

A project made by `kajo new` or by the Kajo app's New App… has
`KAJO_NATIVE: YES`: its Release build generates, compiles and links the
sealed image's native module with no flag. `AppProjectSpec.native` defaults
to `true`; `kajo new --no-native` writes `NO` and `--native` is still
accepted (the last of the two wins; `NewArguments.parse` in `KajoGenerator`
is the one parser, and an unknown option is refused). `KAJO_NATIVE=NO` on
one `xcodebuild` line builds without the module. A failed native step stops
the Release build with one line: "error: the native module was not built:
kajo aot failed. Set KAJO_NATIVE=NO (in project.yml, or on the xcodebuild
line) to build the app without it; it then runs interpreted." Before, the
only message was Xcode's "PhaseScriptExecution failed". `build-native.sh`
removes the libraries of keys no platform links, so a changed image leaves
one library per platform. Debug builds, existing projects and the shells
did not change. Nothing under the core directories or `Sources/KajoAOT/`
changed.

One thing was added that the brief had as a starting position to check: a
Release app could not report frames. `kajo-frames=` moved from
`KajoAppDevelopment` into `KajoApp` (`Sources/KajoApp/Frames.swift`:
`FrameWindow`, `FrameAccount`), so a Release build prints a frames line.

## Part 1, measured before the generator changed

The rule was written first (`part1/rule.txt`, 05:32:43, before any number).

The Sample, Release, module off against on, five launches a side in both
orders, thermal nominal on every line (`part1/sample-table.md`): the on
launches missed 0 frames on the Mac, the iPhone and the iPad; the off
launches missed 0, 0 and 2 (the iPad's first launch after install). First
frame, on minus off, medians: Mac +0.7 and +12.3 ms by order, iPhone +1.6
and +14.6, iPad -4.0 and +12.0; inside the 20 ms rule everywhere. The side
run second in an order is the slower one by 12 to 15 ms on all three
devices, which is an order effect about as large as the bind itself. Bind:
Mac 5.19 to 5.39 ms, iPhone 5.52 to 6.19, iPad 8.53 to 9.46; every on launch
printed `native=bound methods=3290 bound=1433 ... declined=0`.

The shells' scenario matrix, native in the product's configuration against
interpreted (156 rows a matrix; `part1/{mac,iphone,ipad}-compare.md`). The
shells' modules have been in the product's configuration since AOT 2
(`build-images.sh` passes no options), so AOT 1's native rows did not speak
for the default and all were run again. Every matrix: 0 failed launches, 0
bad checksums, 0 fallbacks. Frames missed outside the hog rows with the
budget off:

- Mac, 7 workers, one order: 0 in both engines, every row kind.
- iPhone, 5 workers, both orders: the ring under `young=stw` missed 137
  frames in 6 interpreted rows (largest 35) and 111 in 6 native rows
  (largest 27); the storm under `young=stw` missed 1 frame in 1 of 6 native
  rows and 0 interpreted, which is "not met" by the rule for that row kind.
- iPad, 5 workers, both orders (its first matrix in both engines): the ring
  under `young=stw` missed 10 frames interpreted (0, 0, 0 and 3, 4, 3) and
  28 native (3, 3, 7 and 7, 3, 5): "not met" for that row kind.
- Every other row kind, and every row under `local` and `offload`, missed 0
  in both engines on all three machines.

Read with the thermal states (the main session's reading of the raw rows):
every iPhone scenario row of all four blocks was at "serious", and the
weekly run's cool phone missed 10 frames in the same three interpreted rows
that morning, so the 137 is the hot phone and not the commit. On the iPad
the only block not wholly at "serious" was the first interpreted one (8 rows
at "fair"), and it is the one that missed 0; the interpreted block run hot
missed 3, 4, 3 against native's 3 to 7. So the iPad's "not met" is partly
the order the blocks ran in. Both rows are the stop-the-world young mode,
the oracle; the default mode missed nothing.

## Sizes and times

`new-check` (`part3/new-check.txt`): the Mac Release binary 5 068 832 bytes
with the module and 2 236 672 without (the app 11 540 against 8 776 KiB);
iOS 4 951 272 against 2 126 008; the simulator 4 974 936 against 2 126 136.
The Mac Release build with the module (`part2/builds-mac.txt`): 9.47 s from
clean (AOT 2: 10), 5.35 s after a changed image, 1.20 s unchanged, 1.72 s
with `KAJO_NATIVE=NO`.

## Gates

The Swift tier on 0f3c282 (`check/gates.log`, 16 files chose it; swift.org
6.4.2 and swiftly's clang): clean-build 20 s, swift-test 771 s (the weekly
on 30e14bd: 744), tsan 3007 s (AOT 2: 2924), kernel-test 106 s, apps 127 s,
new-check 264 s (the weekly: 302; it builds more rows now and its builds
were warm); every gate `rc=0`, 461 and 164 tests in both test gates, 0
sanitizer reports, 249 of 249 kernel tests. The two Symbol interning tests
the weekly run of the same morning failed passed in both test gates here,
the broken variant in round 33 of 40 without the sanitizer.

The broken variant of `new-check` (a `--no-native` project) fails "a plain
Release binary has no module section" and seven more lines
(`part3/new-check-broken2.txt`); it also found that the cache rows of a
project with no library wrote two files into the directory the script ran
from, fixed in 0f3c282. The new generator test fails on the starting commit
with 4 expectations (`part2/start-test.log`).

## Deviations and not done

- Part 1 added code (the frames line), as the brief allowed.
- The Mac matrix ran in one order.
- The CLI's flags are tested through `NewArguments`, with one run of the
  binary for each flag quoted (`part2/cli-runs.txt`).
- `app-roundtrip.sh mac` passed every step but finding the Sample by its
  Bonjour name; `dns-sd -B` printed nothing at all in the agent's session,
  so the step fell back to the address. Not explained.
- Not done: Release build times on the devices; the kernel's tests through
  the Sample and a native `kajo-bench` (not in the module).

## Found, not the module's

- `new-check`'s `image-phase` row reads 0.14 s with an empty `phase.log`,
  as in the weekly and AOT 2 baselines; it may not time a real image build.
- The weekly run of 2026-11-16 failed three test gates on two Symbol
  interning tests that wait for a race by repeating rounds
  (`docs/decisions/36-gate-speed-follow-ups.md` has the same kind of fix for
  the stall tests). The owner asked for the fix the same day; it is the
  next module.

## Open questions

1. `--native` on `kajo new`: built kept and accepted (recommended), or
   removed.
2. A failed native step: built to stop the Release build and name the
   setting (recommended), or to go on interpreted with a warning.
3. The cache: built as one library per platform (recommended), or the last
   few kept.
4. Frames missed in two device row kinds under `young=stw` with the module
   on, both with 0 fallbacks: the default stays as answered and the rows
   are reported (recommended), or the default is held until they are
   explained. The same rows run cool, both engines interleaved, would
   settle how much is the engine.

Answered by the owner on 2026-11-16, after asking what the two
stop-the-world rows mean for a real app (they are the oracle mode, not the
default; the devices were hot): "Ok, then I accept all four as recommended".

1. `--native` stays an accepted flag of `kajo new`, as recommended.
2. A failed native step stops the Release build and names `KAJO_NATIVE=NO`,
   as recommended.
3. The cache keeps one library per platform, as recommended.
4. The default stays on, as recommended. A cool, interleaved run of the two
   row kinds was offered and is not planned.
