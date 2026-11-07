#!/bin/zsh
# Module 11a's round trip (docs/modules/app-project.md, part 4): the Sample
# app made by `kajo new`, its Debug build run on a host and developed live
# from this Mac, then rebuilt, then its Release build.
#
#   scripts/app-roundtrip.sh mac|device <outdir> [launches]
#
# mac: the Mac target, run here. device: the iOS target on DEVICE (the
# iPhone by default; DD names its DerivedData) through scripts/device.sh,
# bundle identifier dev.katajamaki.kajo.sample. The steps, each line of
# results appended to <outdir>/roundtrip-<host>.txt:
#
#  1. generate <outdir>/Sample if it is not there (the working tree as Kajo),
#     build Debug (timed), build again with nothing changed (timed)
#  2. <launches> cold launches of the Debug build to the first frame
#  3. the Debug build serving with no client for 10 s: frames missed
#  4. a 30 s window of the Debug build while the Mac connects by Bonjour
#     name: CLI round trips (`kajo eval`, a process each), a compile of the
#     button's action written to <outdir>/Sample/src and the time until a
#     press shows the change, then the tools (the macOS shell's
#     mode=devsession session=app) doing the same with another source;
#     frames missed over the window
#  5. the project's src/ holds the tools' change; build Debug again (timed)
#     and the relaunched app starts with it (no reply from it is a FAILED
#     line, never starts_with_change=0)
#
# When no Bonjour name is seen the Mac connects by the address on its own
# network and the port, both read from the console of the launch it is
# about to talk to: every launch listens on a new port.
#  6. build Release (timed), <launches> cold launches, and the Release app
#     does not serve (no Bonjour service, no serving line; on the Mac no
#     listening socket)
#
# The token goes from the app's own file (the Mac's Application Support,
# the device's app container) to a targets file of mode 0600 and from there
# into the client's memory; it is never printed.
set -uo pipefail
root=${0:A:h:h}
host=${1:?mac|device} out=${2:?outdir} n=${3:-5}
mkdir -p $out
out=${out:A}
res=$out/roundtrip-$host.txt
proj=$out/Sample
kajo=$(swift build --package-path $root --product kajo --show-bin-path)/kajo
swift build --package-path $root --product kajo > /dev/null || exit 1
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' }
since() { perl -e "printf \"%.3f\", $(now) - $1" }
note() { print -r -- "$*" | tee -a $res }
targets=$out/targets-$host
tok=$out/tok-$host
mkdir -p $tok && chmod 700 $tok
export KAJO_TARGETS=$targets

if [[ ! -d $proj ]]; then
  (cd $out && $kajo new Sample --bundle-id dev.katajamaki.kajo.sample --team BDN6M642M2 --kajo $root) > /dev/null || exit 1
fi
[[ -d $out/src-pristine ]] || cp -R $proj/src $out/src-pristine

case $host in
  mac)
    DDM=${DD:-$out/dd-mac}
    build() {
      local t0=$(now)
      gtimeout 2400 xcodebuild -project $proj/Sample.xcodeproj -scheme Sample-macOS -configuration $1 -derivedDataPath $DDM build \
        > $out/build-mac-$1.log 2>&1 || { grep -E "error:" $out/build-mac-$1.log | sort -u; return 1; }
      note "build host=mac config=$1 seconds=$(since $t0) $2"
    }
    app() { print $DDM/Build/Products/$1/Sample.app }
    # launch <config> <tag> args...: one launch, its result lines to $res
    launch() {
      local c=$1 tag=$2; shift 2
      rm -f $out/console-$tag.log  # a reused <outdir>: no earlier launch's lines
      gtimeout ${TIMEOUT:-90} $(app $c)/Contents/MacOS/Sample "$@" > $out/console-$tag.log 2>&1
      grep -E '^mode=app run=' $out/console-$tag.log | sed "s/^/host=mac tag=$tag /" >> $res
    }
    token_file="$HOME/Library/Application Support/dev.katajamaki.kajo.sample/kajo-pairing-token"
    gettoken() {
      [[ -s $token_file ]] || return 1
      (umask 077; printf 'app\t%s\t%s\n' "$1" "$(cat $token_file)" > $targets)
    }
    ;;
  device)
    export PROJECT=$proj/Sample.xcodeproj SCHEME=Sample-iOS PRODUCT=Sample BUNDLE=dev.katajamaki.kajo.sample
    export DD=${DD:-${TMPDIR:-/tmp}/kajo-sample-ios}
    build() {
      local t0=$(now)
      CONFIG=$1 $root/scripts/device.sh build || return 1
      note "build host=device device=${DEVICE:-iphone} config=$1 seconds=$(since $t0) $2"
    }
    app() { print $DD/Build/Products/$1-iphoneos/Sample.app }
    launch() {
      local c=$1 tag=$2; shift 2
      rm -f $out/lines-$tag.txt $out/lines-$tag-console.log  # a reused <outdir>: no earlier launch's lines
      TIMEOUT=${TIMEOUT:-90} $root/scripts/device.sh run $out/lines-$tag.txt "$@"
      sed "s/^/host=device tag=$tag /" $out/lines-$tag.txt 2>/dev/null | grep 'mode=app run=' >> $res
      cp $out/lines-$tag-console.log $out/console-$tag.log 2>/dev/null
    }
    gettoken() {
      $root/scripts/device.sh token $tok/t by-address > /dev/null || return 1
      (umask 077; awk -F'\t' -v a="$1" '{printf "app\t%s\t%s\n", a, $3}' $tok/t > $targets)
      rm -f $tok/t
    }
    ;;
  *) print "app-roundtrip: mac or device"; exit 2 ;;
esac

sizes() {
  local a=$(app $1)
  local bin=$a/Sample; [[ -f $a/Contents/MacOS/Sample ]] && bin=$a/Contents/MacOS/Sample
  local dylib=${bin}.debug.dylib
  local img=$(find $a -name app.img | head -1)
  note "size host=$host config=$1 app_kib=$(du -sk $a | cut -f1) binary_bytes=$(stat -f %z $bin) debug_dylib_bytes=$([[ -f $dylib ]] && stat -f %z $dylib || print 0) image_bytes=$(stat -f %z $img)"
}

# The service the app advertises, once it is there (15 s at most).
service() {
  local name=""
  for i in {1..5}; do
    name=$(gtimeout 3 dns-sd -B _kajo-dev._tcp local 2>/dev/null | awk -v want="$1" '/Add/ && /_kajo-dev/ {n=""; for (i=7;i<=NF;i++) n=n (i>7?" ":"") $i; if (index(n, want) == 1) {print n; exit}}')
    [[ -n $name ]] && break
  done
  print -r -- $name
}

# The console of launch <tag> as far as it has come: on a device the last
# launch's block of its streamed console (device.sh appends every launch to
# one file, each after a "== " line), on the Mac the launch's own file.
console_of() {
  local f=$out/lines-$1-console.log
  if [[ $host == device ]]; then
    [[ -f $f ]] && awk '/^== /{l=""} {l=l $0 "\n"} END{printf "%s", l}' $f
  else
    cat $out/console-$1.log 2>/dev/null
  fi
}

# Wait (60 s at most) for launch <tag>'s serving line.
wait_serving() {
  for i in {1..300}; do console_of $1 | grep -q "^serving=tcp" && return 0; sleep 0.2; done
  return 1
}

# The address to reach launch <tag> at: its Bonjour name when one was seen
# ($name), else the address on this Mac's network and the port from that
# launch's own serving line (every launch listens on a new port).
address_of() {
  if [[ -n $name ]]; then print -r -- "bonjour:$name"; return; fi
  local mine=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1)
  local line=$(console_of $1 | grep "^serving=tcp" | head -1)
  local port=$(print -r -- $line | sed -n 's/.*port=\([0-9]*\).*/\1/p')
  local ip=$(print -r -- $line | sed -n 's/.*addresses=\([^ ]*\).*/\1/p' | tr ',' '\n' | grep -F "${mine%.*}." | head -1)
  [[ -n $ip && -n $port ]] && print -r -- "tcp://$ip:$port"
}

# 1. Debug, first and again.
build Debug first || exit 1
build Debug unchanged || exit 1
sizes Debug

# 2. Cold launches of Debug.
for (( k = 1; k <= n; k++ )); do launch Debug debug-launch-$k kajo-launch-report kajo-frames=1; done

# 3. Serving with no client.
launch Debug debug-idle kajo-frames=10

# 4. The live window.
launch Debug debug-live kajo-frames=30 &
lpid=$!
wait_serving debug-live || note "FAILED host=$host step=live (no serving line in 60 s)"
name=$(service "Sample on")
note "service host=$host name=${name// /_}"
if [[ -z $name ]]; then
  # No advertisement seen (on a device, iOS's local-network prompt waits
  # for the owner): by the address on this Mac's network, from the console.
  note "FAILED host=$host step=bonjour (no Sample service seen; trying the address)"
fi
addr=$(address_of debug-live)
[[ -z $name ]] && note "address host=$host tag=debug-live addr=$addr"
if [[ -n $addr ]]; then
  gettoken "$addr" || note "FAILED host=$host step=token"
  for k in 1 2 3 4 5; do
    t0=$(now)
    v=$(gtimeout 30 $kajo eval --target app 'SampleApp labelText' 2>&1)
    note "cli host=$host request=evaluate k=$k seconds=$(since $t0) ok=$([[ $v == *'"class":"String"'* ]] && print 1 || print 0)"
  done
  print -r -- "pressed
	\"The button's action: count the press and show the count.\"
	presses := presses + 1.
	label text: 'Changed from the CLI: ' , presses printString" > $out/source-cli.st
  t0=$(now)
  c=$(gtimeout 30 $kajo compile --target app --package Sample --project $proj/src SampleApp --side class --category actions --file $out/source-cli.st 2>&1)
  compiled=$(since $t0)
  live=0
  for i in {1..50}; do
    v=$(gtimeout 30 $kajo eval --target app 'SampleApp pressed. SampleApp labelText' 2>&1)
    [[ $v == *"Changed from the CLI"* ]] && { live=1; break; }
  done
  note "cli host=$host request=compile seconds=$compiled live=$live compile_to_live_seconds=$(since $t0) written=$(grep -c 'Changed from the CLI' $proj/src/SampleApp.class.st)"
  # The tools: the macOS shell's scripted session against the app.
  print -r -- "pressed
	\"The button's action: count the press and show the count.\"
	presses := presses + 1.
	label text: 'Changed by the tools: ' , presses printString" > $out/source-tools.st
  # The shell's own DerivedData (DD names the sample's here).
  DD=${SHELL_DD:-${TMPDIR:-/tmp}/kajo-shell-mac} TIMEOUT=120 $root/scripts/mac-shell.sh run $out/tools-$host.txt mode=devsession classes=0 target=app targets=$targets \
    session=app package=Sample appclass=SampleApp selector=pressed source=$out/source-tools.st \
    "probe=SampleApp pressed. SampleApp labelText copyFrom: 1 to: 21" "expect=Changed by the tools:" project=$proj/src tag=$host
  tail -1 $out/tools-$host.txt | sed "s/^/tools host=$host /" >> $res
fi
wait $lpid

# 5. The change is in src/; the next build starts with it.
note "src host=$host tools_change_written=$(grep -c 'Changed by the tools' $proj/src/SampleApp.class.st)"
build Debug changed || exit 1
launch Debug debug-rebuilt kajo-frames=8 &
lpid=$!
wait_serving debug-rebuilt || note "FAILED host=$host step=rebuilt (no serving line in 60 s)"
sleep 1
# The rebuilt app listens on a new port: its own address, not the live one's.
raddr=$(address_of debug-rebuilt)
[[ -z $name ]] && note "address host=$host tag=debug-rebuilt addr=$raddr"
v=""
if [[ -n $raddr ]]; then
  gettoken "$raddr" || note "FAILED host=$host step=token"
  v=$(gtimeout 30 $kajo eval --target app 'SampleApp pressed. SampleApp labelText' 2>&1)
fi
if [[ $v == *'"class":"String"'* ]]; then
  note "rebuilt host=$host addr=$raddr starts_with_change=$([[ $v == *"Changed by the tools: 1"* ]] && print 1 || print 0)"
else
  # No answer is not "started without the change".
  note "FAILED host=$host step=rebuilt (no reply from ${raddr:-no address}: $(print -r -- $v | head -1 | cut -c1-120))"
fi
wait $lpid

# 6. Release.
build Release first || exit 1
sizes Release
for (( k = 1; k <= n; k++ )); do TIMEOUT=6 launch Release release-launch-$k kajo-launch-report; done
TIMEOUT=12 launch Release release-serve kajo-launch-report &
lpid=$!
sleep 5
rname=$(service "Sample on")
listening=0
if [[ $host == mac ]]; then
  for p in $(pgrep -f "Release/Sample.app/Contents/MacOS/Sample"); do
    (( listening += $(lsof -nP -a -p $p -iTCP -sTCP:LISTEN 2>/dev/null | grep -c LISTEN) ))
  done
fi
wait $lpid
note "release host=$host serves=$([[ -n $rname ]] && print 1 || print 0) serving_line=$(grep -c '^serving=' $out/console-release-serve.log 2>/dev/null) listening_sockets=$listening"
rm -rf $tok
print "app-roundtrip $host: $(grep -c FAILED $res) failures, results in $res"
