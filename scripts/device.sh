#!/bin/zsh
# Module 9a: build, install and run the iOS shell on the attached iPhone, one
# mode per launch, results streamed back (`--console`) and copied from the
# app's Documents.
#
#   scripts/device.sh build                 build (Release, signed) and install
#   scripts/device.sh run <out> key=value.. one launch: its result lines are
#                                           appended to <out>; the Documents
#                                           files are copied next to it
#   scripts/device.sh tests <dir>           the kernel tests on device: the
#                                           NDJSON stream, junit.xml, the summary
#
# DEVICE (UDID), TEAM, DD (DerivedData) and TIMEOUT override the defaults.
# Signing is automatic (`-allowProvisioningUpdates`): Xcode needs an account
# for TEAM (Xcode > Settings > Accounts) to make the development profile.
set -uo pipefail
root=${0:A:h:h}
DEVICE=${DEVICE:-00008110-001855C63642801E}
TEAM=${TEAM:-BDN6M642M2}
BUNDLE=dev.katajamaki.kajo.shell
DD=${DD:-${TMPDIR:-/tmp}/kajo-shell-ios}
TIMEOUT=${TIMEOUT:-300}
APP=$DD/Build/Products/Release-iphoneos/KajoShell.app

build() {
  (cd $root/apps/KajoShell-iOS && command -v xcodegen > /dev/null && xcodegen generate > /dev/null)
  gtimeout 2400 xcodebuild -project $root/apps/KajoShell-iOS/KajoShell-iOS.xcodeproj -scheme KajoShell \
    -configuration Release -destination "id=$DEVICE" -derivedDataPath $DD -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=$TEAM build > $DD-build.log 2>&1 || { grep -E "error:" $DD-build.log | sort -u; return 1; }
  gtimeout 300 xcrun devicectl device install app --device $DEVICE $APP > /dev/null || return 1
}

# run <out> args...: one launch, its lines (the result lines start with
# "mode=") appended to <out> with the wall clock.
run() {
  local out=$1; shift
  local log=${out%.*}-console.log
  print "== $(date +%s) $*" >> $log
  gtimeout $TIMEOUT xcrun devicectl device process launch --device $DEVICE --console --terminate-existing \
    $BUNDLE "$@" >> $log 2>&1
  local rc=$?
  local lines=$(awk '/^== /{l=""} {l=l $0 "\n"} END{printf "%s", l}' $log | grep -E '^mode=[a-z]+ run=' || true)
  if [[ -z $lines ]]; then print "FAILED=1 rc=$rc at=$(date +%s) $*" >> $out; return 1; fi
  print -r -- "$lines" | sed "s/^/at=$(date +%s) /" >> $out
}

# copy <dir>: the app's Documents into <dir>.
copy() {
  mkdir -p $1
  gtimeout 120 xcrun devicectl device copy from --device $DEVICE --domain-type appDataContainer \
    --domain-identifier $BUNDLE --source Documents --destination $1 > /dev/null 2>&1
}

case ${1:-} in
  build) build ;;
  run) shift; run "$@" ;;
  copy) shift; copy "$@" ;;
  tests)
    dir=${2:?tests <dir>}
    mkdir -p $dir
    run $dir/tests.txt mode=tests out=tests-results.txt && copy $dir/documents
    ;;
  *) print "usage: device.sh build | run <out> key=value... | copy <dir> | tests <dir>"; exit 2 ;;
esac
