#!/bin/zsh
# Fuzz one of the readers of untrusted bytes (the kasm and snapshot loaders,
# module 8b's Smalltalk syntax: Tonel files and method sources, and module
# 9b's development protocol requests):
#   scripts/fuzz.sh kasm|snapshot|syntax|protocol [seconds]
# libFuzzer needs a toolchain with libclang_rt.fuzzer_osx.a. Xcode's has
# none ("unsupported option '-sanitize=fuzzer' for target
# 'arm64-apple-macos15.0'"); a swift.org toolchain does. It is selected with
# TOOLCHAINS (default `swift`, the installed swift.org toolchain; override
# with KAJO_FUZZ_TOOLCHAINS=<bundle id>). The targets are built with
# -sanitize=fuzzer,address -DKAJO_LIBFUZZER; new corpus entries go to
# .build/fuzz-run/<target>/corpus, crashes to .build/fuzz-run/<target>/.
# Without such a toolchain this falls back to the same target built
# plainly: it replays the seed corpus and mutates it, without coverage
# guidance, for the given time.
set -uo pipefail
cd "$(dirname "$0")/.."
root=$PWD
target=${1:?kasm, snapshot, syntax or protocol}
seconds=${2:-60}
[[ $target == kasm || $target == snapshot || $target == syntax || $target == protocol ]] || { echo "target: kasm, snapshot, syntax or protocol"; exit 2; }
seeds=$root/Tests/KajoVMTests/Fixtures/fuzz/$target
run=$root/.build/fuzz-run/$target
mkdir -p $run/corpus
log=$run/libfuzzer-build.log
toolchains=${KAJO_FUZZ_TOOLCHAINS:-swift}
# Under swiftly the `swift` on the path is already the swift.org toolchain,
# and swiftly refuses to run with TOOLCHAINS set: set it only for Xcode's.
tc=()
swift --version 2>&1 | grep -q 'swiftlang-' && tc=(TOOLCHAINS=$toolchains)  # Xcode's names its build swiftlang-
flags=(-c release --product fuzz-$target --scratch-path .build/fuzz -Xswiftc -sanitize=fuzzer,address -Xswiftc -DKAJO_LIBFUZZER)
if env $tc swift build $flags >$log 2>&1; then
  bin=$(env $tc swift build $flags --show-bin-path)/fuzz-$target
  echo "libFuzzer build: ok ($(env $tc swift --version 2>&1 | head -1))"
  cd $run && $bin -max_total_time=$seconds -print_final_stats=1 corpus $seeds
  exit $?
fi
echo "libFuzzer build failed: $(grep -m1 -E 'error' $log)"
echo "falling back to the corpus replay and mutation driver (no coverage guidance)"
swift build -c release --product fuzz-$target >/dev/null || exit 2
bin=$(swift build -c release --product fuzz-$target --show-bin-path)/fuzz-$target
cd $run && $bin --seconds $seconds --seed $RANDOM $seeds
