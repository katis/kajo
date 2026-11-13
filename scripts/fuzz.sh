#!/bin/zsh
# Fuzz one of the readers of untrusted bytes (the kasm and snapshot loaders,
# module 8b's Smalltalk syntax: Tonel files and method sources, and module
# 9b's development protocol requests):
#   scripts/fuzz.sh kasm|snapshot|syntax|syntax-kernel|protocol [seconds]
#   scripts/fuzz.sh --build <target>            (build only)
#   scripts/fuzz.sh --run <target> [seconds]    (run what --build built)
# syntax-kernel is the syntax target's kernel mode (the review fixes, part
# 2, item 7): every input is compiled by the kernel's compiler too, in a
# kernel image built from kernel/ at the start, and the two outcomes are
# compared; a disagreement is a crash with the source in its message.
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
#
# Gate speed (docs/modules/gate-speed.md, change 2): --build and --run split
# the two halves so scripts/fuzz-gate.sh can build the targets one after
# another (they share .build/fuzz) and run them side by side. --build
# prints the "libFuzzer build: ok" line (or the fallback's) and records the
# binary and its kind in .build/fuzz-run/<target>/build.txt; --run reads
# it. With neither, both halves run, as before.
set -uo pipefail
cd "$(dirname "$0")/.."
root=$PWD
mode=all
case ${1:-} in
  --build) mode=build; shift ;;
  --run) mode=run; shift ;;
esac
target=${1:?kasm, snapshot, syntax, syntax-kernel or protocol}
seconds=${2:-60}
[[ $target == kasm || $target == snapshot || $target == syntax || $target == syntax-kernel || $target == protocol ]] || { echo "target: kasm, snapshot, syntax, syntax-kernel or protocol"; exit 2; }
run=$root/.build/fuzz-run/$target
if [[ $target == syntax-kernel ]]; then
  export KAJO_FUZZ_KERNEL=$root/kernel
  target=syntax
fi
seeds=$root/Tests/KajoVMTests/Fixtures/fuzz/$target
mkdir -p $run/corpus
log=$run/libfuzzer-build.log
record=$run/build.txt

build() {
  rm -f $record
  local toolchains=${KAJO_FUZZ_TOOLCHAINS:-swift}
  # Under swiftly the `swift` on the path is already the swift.org toolchain,
  # and swiftly refuses to run with TOOLCHAINS set: set it only for Xcode's.
  local tc=()
  swift --version 2>&1 | grep -q 'swiftlang-' && tc=(TOOLCHAINS=$toolchains)  # Xcode's names its build swiftlang-
  local flags=(-c release --product fuzz-$target --scratch-path .build/fuzz -Xswiftc -sanitize=fuzzer,address -Xswiftc -DKAJO_LIBFUZZER)
  if env $tc swift build $flags >$log 2>&1; then
    print -r -- "libfuzzer $(env $tc swift build $flags --show-bin-path)/fuzz-$target" > $record
    echo "libFuzzer build: ok ($(env $tc swift --version 2>&1 | head -1))"
    return 0
  fi
  echo "libFuzzer build failed: $(grep -m1 -E 'error' $log)"
  echo "falling back to the corpus replay and mutation driver (no coverage guidance)"
  swift build -c release --product fuzz-$target >/dev/null || return 2
  print -r -- "fallback $(swift build -c release --product fuzz-$target --show-bin-path)/fuzz-$target" > $record
  return 0
}

runit() {
  [[ -r $record ]] || { echo "fuzz.sh --run $target: nothing built (run --build first)"; return 2; }
  local kind bin
  read -r kind bin < $record
  cd $run
  if [[ $kind == libfuzzer ]]; then
    $bin -max_total_time=$seconds -print_final_stats=1 corpus $seeds
  else
    $bin --seconds $seconds --seed $RANDOM $seeds
  fi
}

case $mode in
  build) build; exit $? ;;
  run) runit; exit $? ;;
  all) build || exit $?; runit; exit $? ;;
esac
