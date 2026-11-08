# Common development commands. Run `just` to list them.

default:
    @just --list

# Build everything in debug
build:
    swift build

# Run the test suite
test:
    swift test

# Release build
release-build:
    swift build -c release

# Run the headless CLI
run *ARGS:
    swift run kajo {{ARGS}}

# Re-run the language benchmark experiment
bench:
    experiments/vm-language-bench/bench.sh

# The runtime comparison (about an hour, nothing else running), then `just bench` into the comparison's slices-raw.txt (the language experiment's own raw file stays as published), then the performance report (docs/performance/)
perf:
    experiments/runtime-comparison/bench.sh
    OUT=$PWD/experiments/runtime-comparison/slices-raw.txt just bench
    just perf-report

# The performance report's tables and SVGs regenerated from the raw files alone (docs/performance/README.md)
perf-report:
    scripts/perf-report.py

# Check that the VM core compiles for iOS (every file under Sources/KajoVM), in the package's language mode (6)
ios-check:
    xcrun swiftc -typecheck -target arm64-apple-ios18.0 -sdk $(xcrun --sdk iphoneos --show-sdk-path) -swift-version 6 \
        -parse-as-library -module-name KajoVM -package-name kajo -strict-memory-safety $(find Sources/KajoVM -name '*.swift')

# Release disassembly: no retain/release on the allocation, store, dispatch, send and primitive paths; one jump table
arc-check:
    scripts/check-hot-path-arc.sh

# Fuzz a reader (kasm, snapshot, syntax or protocol) for SECONDS: libFuzzer if the toolchain has it, else replay and mutate
fuzz TARGET SECONDS="60":
    scripts/fuzz.sh {{TARGET}} {{SECONDS}}

# The fixture kernels through `kajo run` against their published single-worker checksums
golden:
    scripts/golden.sh

# The test suite in a release build, which adds the full-size golden kernels
test-release:
    swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests

# A thousand randomized programs under every configuration, in a release build with -enable-testing (SEEDS, BASE override)
soak SEEDS="1000" BASE="1":
    KAJO_SEEDS={{SEEDS}} KAJO_SEED_BASE={{BASE}} swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests --filter randomPrograms

# Exhaustive interleaving models of the concurrent protocols (docs/models/).
model-check:
    cd models && swift test

# Module 8b: build the kernel image from kernel/ (OUT defaults to kernel.img)
build-image OUT="kernel.img":
    swift run kajo build-image -o {{OUT}}

# Module 8b: build kernel/ and run its tests headless (NDJSON on stdout)
kernel-test *ARGS:
    swift run kajo test {{ARGS}}

# Module 9a: build both shells with xcodebuild from clean (the iOS one unsigned, for the compile), 0 warnings and 0 errors or fail
apps:
    scripts/apps-check.sh

# Module 11a: `kajo new` writes the Sample app, both targets built in both configurations from clean (0 warnings), the Release products checked for the protocol
new-check OUT="":
    scripts/new-check.sh {{OUT}}

# Module 9a: the macOS shell (`just mac-shell build`, `just mac-shell run <out> mode=... key=value`)
mac-shell *ARGS:
    scripts/mac-shell.sh {{ARGS}}

# Module 9c: the development image, kernel/ and tools/ (OUT defaults to dev.img)
dev-image OUT="dev.img":
    swift run kajo build-image -o {{OUT}} --with tools

# Module 9c: the developer UI: the development image in the macOS shell, its tools on its own socket, changes written to tools/
tools:
    just dev-image dev.img
    scripts/mac-shell.sh build
    ${DD:-${TMPDIR:-/tmp}/kajo-shell-mac}/Build/Products/Release/Kajo.app/Contents/MacOS/Kajo mode=dev image=$PWD/dev.img project=$PWD/tools

# Module 9a: the iOS shell on the attached iPhone (`just device build`, `just device tests <dir>`, `just device run <out> mode=...`)
device *ARGS:
    scripts/device.sh {{ARGS}}

# Module 9a: the measurement matrix on the Mac's display or the iPhone (`just shell-matrix mac <outdir>`)
shell-matrix TARGET OUT *PARTS:
    scripts/shell-matrix.sh {{TARGET}} {{OUT}} {{PARTS}}

# Gate tiers: the gates a diff owes against BASE (origin/master), decided from the files it touches and run one after another (`scripts/check-tier.sh --dry-run|--tier`; KAJO_CHECK_OUT, default .build/check/<date>/)
check *ARGS:
    scripts/check-tier.sh {{ARGS}}

# Gate tiers: the weekly run by hand (every gate with its load loops, the Mac and device matrices, ~/kajo-weekly/<date>/summary.md; KAJO_WEEKLY_QUICK=1 for the quick mode)
weekly:
    scripts/weekly.sh

# Gate tiers: the weekly LaunchAgent (Sundays 02:00) copied to ~/Library/LaunchAgents/ with this checkout's paths; prints the launchctl command, loads nothing
weekly-install:
    #!/bin/zsh
    set -euo pipefail
    src=scripts/launchd/dev.katajamaki.kajo.weekly.plist
    dst=$HOME/Library/LaunchAgents/dev.katajamaki.kajo.weekly.plist
    mkdir -p $HOME/kajo-weekly $HOME/Library/LaunchAgents
    sed -e "s|__HOME__|$HOME|g" -e "s|__REPO__|$PWD|g" $src > $dst
    plutil -lint $dst
    print "installed $dst (not loaded). To load it:"
    print "  launchctl bootstrap gui/$(id -u) $dst"
    print "To unload it:"
    print "  launchctl bootout gui/$(id -u)/dev.katajamaki.kajo.weekly"

# Gate tiers: launchd's view of the weekly LaunchAgent (loaded or not, last exit, next run)
weekly-status:
    -launchctl print gui/$(id -u)/dev.katajamaki.kajo.weekly
    -tail -5 $HOME/kajo-weekly/weekly.log

# Module 11b: Kajo-<version>.dmg (the Kajo app, the checkout, the prebuilt frameworks), signed, notarized when KAJO_NOTARY_PROFILE names a profile
dist VERSION:
    scripts/dist.sh {{VERSION}}

# Module 11b: tag v0.<n> locally, build its dmg, print the gh release command (uploads nothing; --dry-run only prints)
release TAG *ARGS:
    scripts/release.sh {{TAG}} {{ARGS}}
