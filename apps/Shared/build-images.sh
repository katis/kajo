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
if [[ $platform == product && -n ${KAJO:-} ]]; then
  kajo=$KAJO
else
  $clean swift build --package-path $root --scratch-path $scratch --product kajo > $dst/../kajo-build.log 2>&1 || { cat $dst/../kajo-build.log; exit 1; }
  kajo=$($clean swift build --package-path $root --scratch-path $scratch --product kajo --show-bin-path)/kajo
fi
cd $root
if [[ $platform == product ]]; then
  rmdir $dst/kasm
  $kajo build-image -o $dst/dev.img kernel --with tools > /dev/null
  rm -f $dst/../kajo-build.log
  exit 0
fi
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
# AOT 1, part 5 (docs/modules/aot.md): KAJO_SHELL_AOT=1 in the build's
# environment compiles each bundled image's native module beside it
# (<image>.native.dylib, and kasm/<kernel>.kasm.native.dylib for the golden
# kernels), which the shells bind with the launch argument native=1. The
# default build is unchanged. iOS: Xcode's clang for the device, each dylib
# signed with the build's identity (a dylib dlopen'ed from the bundle must
# be signed by the app's team).
if [[ ${KAJO_SHELL_AOT:-} == 1 ]]; then
  gen=$scratch/aot
  rm -rf $gen
  mkdir -p $gen
  native() {  # native <name> <output dylib> <kajo aot inputs...>
    local name=$1 lib=$2; shift 2
    $kajo aot "$@" -o $gen/$name > /dev/null
    if [[ $platform == mac ]]; then
      (cd $gen/$name && ls kajo_native_*.c | xargs -P 8 -I{} $clean clang -O2 -fPIC -c {} -o {}.o && $clean clang -dynamiclib -o $lib *.o)
    else
      (cd $gen/$name && ls kajo_native_*.c | xargs -P 8 -I{} xcrun --sdk iphoneos clang -target arm64-apple-ios18.0 -O2 -fPIC -c {} -o {}.o \
        && xcrun --sdk iphoneos clang -target arm64-apple-ios18.0 -dynamiclib -install_name @rpath/$(basename $lib) -o $lib *.o)
      if [[ -n ${EXPANDED_CODE_SIGN_IDENTITY:-} ]]; then /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" $lib; fi
    fi
  }
  for img in $dst/*.img; do native $(basename $img .img) $img.native.dylib $img; done
  for k in arith fib sends alloc ivars walk storeheavy closures floats; do
    native kasm-$k $dst/kasm/$k.kasm.native.dylib $dst/kasm/prelude.kasm $dst/kasm/lib.kasm $dst/kasm/$k.kasm
  done
fi
rm -f $dst/../kajo-build.log
