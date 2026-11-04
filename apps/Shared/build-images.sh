#!/bin/zsh
# Module 9a: the images and kernels both shells bundle, built with the
# toolchain first on PATH (swiftly's swift.org toolchain on the mini; the
# image is bytes, the same on every platform). Xcode's "Bundle images" build
# phase runs it with the app's resources directory; by hand:
#   apps/Shared/build-images.sh <dir>
# writes <dir>/kajo/{kernel,shell,st-sends,st-ivars,st-closures}.img and
# <dir>/kajo/kasm/*.kasm.
set -euo pipefail
out=${1:?usage: build-images.sh <resources dir>}
root=${0:A:h:h:h}
dst=$out/kajo
mkdir -p $dst/kasm
# Xcode's environment (SDKROOT for iOS, its toolchain) must not reach the
# host build: a clean environment with the PATH toolchain.
clean=(/usr/bin/env -i HOME=$HOME PATH=$HOME/.swiftly/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin)
scratch=$root/.build/apps-image
$clean swift build --package-path $root --scratch-path $scratch --product kajo > $dst/../kajo-build.log 2>&1 || { cat $dst/../kajo-build.log; exit 1; }
kajo=$($clean swift build --package-path $root --scratch-path $scratch --product kajo --show-bin-path)/kajo
cd $root
$kajo build-image -o $dst/kernel.img kernel > /dev/null
$kajo build-image -o $dst/shell.img kernel apps/Shared/smalltalk > /dev/null
for k in sends ivars closures; do
  $kajo build-image -o $dst/st-$k.img kernel Tests/KajoVMTests/Fixtures/smalltalk/$k > /dev/null
done
for k in prelude lib arith fib sends alloc ivars walk storeheavy closures floats; do
  cp Tests/KajoVMTests/Fixtures/kernels/$k.kasm $dst/kasm/
done
rm -f $dst/../kajo-build.log
