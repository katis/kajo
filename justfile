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

# Check that the VM core compiles for iOS
ios-check:
    xcrun swiftc -typecheck -target arm64-apple-ios18.0 -sdk $(xcrun --sdk iphoneos --show-sdk-path) \
        -parse-as-library -module-name KajoVM -strict-memory-safety Sources/KajoVM/*.swift
