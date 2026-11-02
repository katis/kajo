#!/bin/zsh
# Fuzz one of the two loaders that read untrusted bytes:
#   scripts/fuzz.sh kasm|snapshot [seconds]
# Tries a libFuzzer build first (-sanitize=fuzzer,address -DKAJO_LIBFUZZER).
# The Xcode toolchain does not support it ("unsupported option
# '-sanitize=fuzzer' for target 'arm64-apple-macosx...'", no
# libclang_rt.fuzzer_osx.a); a swift.org toolchain does, selected with
# TOOLCHAINS=<its bundle id> (swiftly or the .pkg from swift.org). Without
# one this falls back to the same target built plainly: it replays the seed
# corpus and mutates it, without coverage guidance, for the given time.
# A trap leaves its input in .build/fuzz-run/<target>/fuzz-current.
set -uo pipefail
cd "$(dirname "$0")/.."
target=${1:?kasm or snapshot}
seconds=${2:-60}
[[ $target == kasm || $target == snapshot ]] || { echo "target: kasm or snapshot"; exit 2; }
seeds=$PWD/Tests/KajoVMTests/Fixtures/fuzz/$target
run=$PWD/.build/fuzz-run/$target
mkdir -p $run/corpus
log=$run/libfuzzer-build.log
if swift build -c release --product fuzz-$target --scratch-path .build/fuzz \
     -Xswiftc -sanitize=fuzzer,address -Xswiftc -DKAJO_LIBFUZZER >$log 2>&1; then
  echo "libFuzzer build: ok"
  cd $run && $PWD/../../fuzz/release/fuzz-$target corpus $seeds -max_total_time=$seconds
  exit $?
fi
echo "libFuzzer build failed: $(grep -m1 -E 'error' $log)"
echo "falling back to the corpus replay and mutation driver (no coverage guidance)"
swift build -c release --product fuzz-$target >/dev/null || exit 2
cd $run && $OLDPWD/.build/release/fuzz-$target --seconds $seconds --seed $RANDOM $seeds
