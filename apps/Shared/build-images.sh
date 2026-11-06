#!/bin/zsh
# Module 9a: the images and kernels both shells bundle, built with the
# toolchain first on PATH (swiftly's swift.org toolchain on the mini; the
# image is bytes, the same on every platform). Xcode's "Bundle images" build
# phase runs it with the app's resources directory; by hand:
#   apps/Shared/build-images.sh <dir> [mac]
# writes <dir>/kajo/{kernel,shell,st-sends,st-ivars,st-closures}.img and
# <dir>/kajo/kasm/*.kasm; with mac (the macOS shell's build) also module 9c's
# development images: dev.img (kernel/, tools/, the scenario loads and the
# scripted session) and dev2000.img (the same with 1806 generated classes of
# 11 methods: 2000 classes, the browser's measurement).
set -euo pipefail
out=${1:?usage: build-images.sh <resources dir> [mac]}
platform=${2:-}
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
if [[ -n ${KAJO_SHELL_CLASSES:-} ]]; then
  # The devices investigation (2026-11-06): KAJO_SHELL_CLASSES=1806 in the
  # environment of the build makes shell.img the scenario image plus that
  # many generated classes of 11 methods (dev2000.img's classes without the
  # tools), so a device serves a 2000-class image. Unset: the plain image.
  gen=$scratch/gen-shell
  rm -rf $gen
  /usr/bin/python3 scripts/gen-classes.py $gen $KAJO_SHELL_CLASSES 11
  $kajo build-image -o $dst/shell.img kernel --with apps/Shared/smalltalk --with $gen > /dev/null
else
  $kajo build-image -o $dst/shell.img kernel apps/Shared/smalltalk > /dev/null
fi
for k in sends ivars closures; do
  $kajo build-image -o $dst/st-$k.img kernel Tests/KajoVMTests/Fixtures/smalltalk/$k > /dev/null
done
if [[ $platform == mac ]]; then
  $kajo build-image -o $dst/dev.img kernel --with tools --with apps/Shared/smalltalk --with apps/Shared/devsession > /dev/null
  gen=$scratch/gen2000
  rm -rf $gen
  /usr/bin/python3 scripts/gen-classes.py $gen 1806 11
  $kajo build-image -o $dst/dev2000.img kernel --with tools --with apps/Shared/smalltalk --with apps/Shared/devsession --with $gen > /dev/null
fi
for k in prelude lib arith fib sends alloc ivars walk storeheavy closures floats; do
  cp Tests/KajoVMTests/Fixtures/kernels/$k.kasm $dst/kasm/
done
rm -f $dst/../kajo-build.log
