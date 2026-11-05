#!/bin/zsh
# Module 9a: build the macOS shell, or run it once in a mode on this Mac's
# display, its result lines appended to a file.
#
#   scripts/mac-shell.sh build
#   scripts/mac-shell.sh run <out> key=value...
#
# Module 9d: the scripted session against another target,
#   scripts/mac-shell.sh run <out> mode=devsession classes=0 target=<name|address> \
#       targets=<targets file> project=<dir> [package=Kernel]
# (target= a name in the targets file, tcp://host:port or bonjour:<name>;
# the token stays in the file, mode 0600, and in the shell's memory), and
# the shell serving over TCP as the phone does:
#   scripts/mac-shell.sh run <out> mode=serve scenario=idle protocol=tcp:<port> tokendir=<dir>
#
# DD (DerivedData) and TIMEOUT override the defaults. The app quits itself
# at the end of every mode but demo.
set -uo pipefail
root=${0:A:h:h}
DD=${DD:-${TMPDIR:-/tmp}/kajo-shell-mac}
TIMEOUT=${TIMEOUT:-300}
APP=$DD/Build/Products/Release/KajoShell.app

case ${1:-} in
  build)
    (cd $root/apps/KajoShell-macOS && command -v xcodegen > /dev/null && xcodegen generate > /dev/null)
    gtimeout 2400 xcodebuild -project $root/apps/KajoShell-macOS/KajoShell-macOS.xcodeproj -scheme KajoShell \
      -configuration Release -derivedDataPath $DD build > $DD-build.log 2>&1 || { grep -E "error:" $DD-build.log | sort -u; exit 1; }
    ;;
  run)
    out=${2:?run <out> key=value...}; shift 2
    dir=${out:h}/${out:t:r}-files
    mkdir -p $dir
    gtimeout $TIMEOUT $APP/Contents/MacOS/KajoShell "$@" outdir=$dir > $dir/last.out 2> $dir/last.err
    rc=$?
    lines=$(grep -E '^mode=[a-z]+ run=' $dir/last.out)
    if [[ -z $lines ]]; then print "FAILED=1 rc=$rc at=$(date +%s) $*" >> $out; pkill -f "$APP/Contents/MacOS/KajoShell"; exit 1; fi
    print -r -- "$lines" | sed "s/^/at=$(date +%s) /" >> $out
    ;;
  *) print "usage: mac-shell.sh build | run <out> key=value..."; exit 2 ;;
esac
