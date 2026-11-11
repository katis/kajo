#!/bin/zsh
# AOT 1's gates (docs/modules/aot.md, Gates), each run in the repository
# root with the release kajo and the clang first on PATH (Xcode's for iOS):
#
#   scripts/native-check.sh golden       the golden kernels under the native
#                                        engine: the published checksums, and
#                                        send counts equal to the interpreter's
#   scripts/native-check.sh kernel-test  the kernel tests with the kernel image
#                                        bound, every method bound, none
#                                        declined; the tools' tests with the
#                                        development image bound
#   scripts/native-check.sh cc           the kernel image's generated C at -O2
#                                        for macOS arm64 and iOS arm64 with
#                                        -Wall -Wextra -Werror
#
# Work goes to a temporary directory, removed at the end. Exit 1 on any
# failure.
set -uo pipefail
cd "$(dirname "$0")/.."
what=${1:?golden|kernel-test|cc}
swift build -c release --product kajo >/dev/null || exit 2
kajo=$(swift build -c release --product kajo --show-bin-path)/kajo
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
k=Tests/KajoVMTests/Fixtures/kernels
fail=0

# module <dir> <inputs...>: generate into <dir> and compile <dir>/m.dylib.
module() {
  local d=$1; shift
  $kajo aot "$@" -o $d > $d.gen.txt || return 1
  (cd $d && ls kajo_native_*.c | xargs -P 8 -I{} clang -O2 -fPIC -c {} -o {}.o && clang -shared -o m.dylib *.o) || return 1
}
field() { print -- "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1 }

case $what in
golden)
  for pair in arith:372800000 fib:24682992 sends:1066666666666668 alloc:41950911 ivars:36383626 walk:9016009025388544 storeheavy:512000 closures:210210000 floats:7499750000; do
    name=${pair%%:*} want=${pair#*:}
    module $tmp/$name $k/prelude.kasm $k/lib.kasm $k/$name.kasm || { print "$name FAIL generate or compile"; fail=1; continue; }
    a=$($kajo run $k/prelude.kasm $k/lib.kasm $k/$name.kasm --workers 1)
    b=$($kajo run $k/prelude.kasm $k/lib.kasm $k/$name.kasm --workers 1 --native $tmp/$name/m.dylib)
    if [[ $(field $b checksum) == $want && $(field $a sends) == $(field $b sends) && $(field $b nativeBound) == $(field $b nativeMethods) && $(field $b nativeSends) != 0 ]]; then
      printf '%-10s ok   %s  sends %s  interpreter %8s ms  native %8s ms\n' $name $want $(field $b sends) $(field $a ms) $(field $b ms)
    else
      printf '%-10s FAIL checksum %s want %s, sends %s against %s, bound %s of %s\n' $name "$(field $b checksum)" $want "$(field $b sends)" "$(field $a sends)" "$(field $b nativeBound)" "$(field $b nativeMethods)"; fail=1
    fi
  done
  for pair in sends:1066666666666668 ivars:36383626 closures:210210000; do
    name=${pair%%:*} want=${pair#*:}
    $kajo build-image -o $tmp/$name.img kernel Tests/KajoVMTests/Fixtures/smalltalk/$name >/dev/null || { print "st-$name FAIL build"; fail=1; continue; }
    module $tmp/st-$name $tmp/$name.img || { print "st-$name FAIL generate or compile"; fail=1; continue; }
    a=$($kajo run $tmp/$name.img --workers 1)
    b=$($kajo run $tmp/$name.img --workers 1 --native $tmp/st-$name/m.dylib)
    if [[ $(field $b checksum) == $want && $(field $a sends) == $(field $b sends) && $(field $b nativeBound) == $(field $b nativeMethods) ]]; then
      printf 'st-%-7s ok   %s  sends %s  interpreter %8s ms  native %8s ms\n' $name $want $(field $b sends) $(field $a ms) $(field $b ms)
    else
      printf 'st-%-7s FAIL checksum %s want %s, sends %s against %s\n' $name "$(field $b checksum)" $want "$(field $b sends)" "$(field $a sends)"; fail=1
    fi
  done ;;
kernel-test)
  $kajo build-image -o $tmp/kernel.img >/dev/null || exit 2
  $kajo build-image -o $tmp/dev.img --with tools >/dev/null || exit 2
  for img in kernel dev; do
    module $tmp/$img $tmp/$img.img || { print "$img FAIL generate or compile"; fail=1; continue; }
    $kajo test $tmp/$img.img --native $tmp/$img/m.dylib > $tmp/$img.ndjson 2> $tmp/$img.err; rc=$?
    grep -E '^kajo test:|^native:' $tmp/$img.err
    n=$(sed -n 's/.*"nativeMethods":"\([0-9]*\)".*/\1/p' $tmp/$img.err); bound=$(sed -n 's/.*"nativeBound":"\([0-9]*\)".*/\1/p' $tmp/$img.err)
    declined=$(sed -n 's/.*"nativeDeclined":"\([0-9]*\)".*/\1/p' $tmp/$img.err)
    if (( rc == 0 )) && [[ -n $n && $n == $bound && $declined == 0 ]]; then print "$img ok: every test passed, $bound of $n methods bound, $declined declined"
    else print "$img FAIL: rc $rc, bound $bound of $n, declined $declined"; fail=1; fi
  done ;;
cc)
  $kajo build-image -o $tmp/kernel.img >/dev/null || exit 2
  $kajo aot $tmp/kernel.img -o $tmp/c || exit 2
  for target in mac ios; do
    cc=(clang); [[ $target == ios ]] && cc=(xcrun --sdk iphoneos clang -target arm64-apple-ios18.0)
    (cd $tmp/c && ls kajo_native_*.c | xargs -P 8 -I{} $cc -O2 -Wall -Wextra -Werror -c {} -o {}.$target.o 2>> ../$target.warnings) || true
    w=$(grep -c 'warning:\|error:' $tmp/$target.warnings 2>/dev/null)
    objs=$(ls $tmp/c/*.$target.o 2>/dev/null | wc -l | tr -d ' '); files=$(ls $tmp/c/kajo_native_*.c | wc -l | tr -d ' ')
    if [[ ${w:-0} == 0 && $objs == $files ]]; then print "$target ok: $files files, 0 warnings, $(cat $tmp/c/*.$target.o | wc -c | tr -d ' ') object bytes"
    else print "$target FAIL: $objs of $files compiled, ${w:-0} warnings or errors"; head -20 $tmp/$target.warnings; fail=1; fi
  done ;;
*) print "native-check: golden, kernel-test or cc"; exit 2 ;;
esac
exit $fail
