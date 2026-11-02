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
release:
    swift build -c release

# Run the headless CLI
run *ARGS:
    swift run kajo {{ARGS}}

# Re-run the language benchmark experiment
bench:
    experiments/vm-language-bench/bench.sh

# Check that the VM core compiles for iOS (every file under Sources/KajoVM)
ios-check:
    xcrun swiftc -typecheck -target arm64-apple-ios18.0 -sdk $(xcrun --sdk iphoneos --show-sdk-path) \
        -parse-as-library -module-name KajoVM -strict-memory-safety $(find Sources/KajoVM -name '*.swift')

# Release disassembly: no retain/release on the allocation, store, dispatch, send and primitive paths; one jump table
arc-check:
    scripts/check-hot-path-arc.sh

# Fuzz a loader (kasm or snapshot) for SECONDS: libFuzzer if the toolchain has it, else replay and mutate
fuzz TARGET SECONDS="60":
    scripts/fuzz.sh {{TARGET}} {{SECONDS}}

# The fixture kernels through `kajo run` against their published single-worker checksums
golden:
    scripts/golden.sh
