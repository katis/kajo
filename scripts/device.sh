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
#   scripts/device.sh serve <out> key=value.. module 9d: one launch serving the
#                                           development protocol over TCP while a
#                                           scenario runs (mode=serve protocol=tcp
#                                           scenario=idle seconds=N by default; the
#                                           console line serving=tcp port=.. addresses=..)
#   scripts/device.sh token <targets> [name] module 9d: the phone's pairing token
#                                           (Application Support, as the phone shows
#                                           it) into a targets file of mode 0600 for
#                                           the Mac's tools: name bonjour:<service>
#                                           token; the token is never printed
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

# serve <out> args...: a launch in serve mode (module 9d).
serve() {
  local out=$1; shift
  run $out mode=serve "$@"
}

# token <targets> [name]: the phone's token, copied from its app container,
# as one line of a targets file only its owner may read. The Bonjour name is
# the one the Mac browses (dns-sd), or <name> when given.
token() {
  local targets=${1:?token <targets file> [bonjour name]} name=${2:-}
  local tmp=$(mktemp -d)
  chmod 700 $tmp
  gtimeout 120 xcrun devicectl device copy from --device $DEVICE --domain-type appDataContainer \
    --domain-identifier $BUNDLE --source "Library/Application Support/kajo-pairing-token" --destination $tmp/kajo-pairing-token > $tmp/copy.log 2>&1 \
    || { grep -iE "error|fail" $tmp/copy.log | head -5; rm -rf $tmp; print "no token: is the shell installed and has it served once?"; return 1; }
  if [[ -z $name ]]; then
    name=$(gtimeout 5 dns-sd -B _kajo-dev._tcp local 2>/dev/null | awk '/Add/ && /_kajo-dev/ {for (i=7;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""; exit}')
  fi
  [[ -n $name ]] || { rm -rf $tmp; print "no _kajo-dev._tcp service on the network"; return 1; }
  (umask 077; printf 'phone\tbonjour:%s\t%s\n' "$name" "$(cat $tmp/kajo-pairing-token)" > $targets)
  rm -rf $tmp
}

case ${1:-} in
  build) build ;;
  run) shift; run "$@" ;;
  serve) shift; serve "$@" ;;
  token) shift; token "$@" ;;
  copy) shift; copy "$@" ;;
  tests)
    dir=${2:?tests <dir>}
    mkdir -p $dir
    run $dir/tests.txt mode=tests out=tests-results.txt && copy $dir/documents
    ;;
  *) print "usage: device.sh build | run <out> key=value... | serve <out> key=value... | token <targets> [name] | copy <dir> | tests <dir>"; exit 2 ;;
esac
