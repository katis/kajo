#!/bin/zsh
# Module 9d: the scripted developer session (mode=devsession) from the
# macOS shell against a target serving the development protocol over TCP,
# and that target's own frames while it serves.
#
#   scripts/remote-session.sh <serve> <outdir> <tag> <scenario> <form> <sessions> [key=value...]
#
#   serve     device: the iOS shell on the attached iPhone (scripts/device.sh serve)
#             mac:    the macOS shell in mode=serve, the phone's code path, on this Mac
#             kajo:   a headless `kajo run shell.img --protocol tcp:<port>`
#   scenario  the serving shell's scenario (idle, ring, ...; ignored for kajo)
#   form      how the session names the target: lan (an address of the network),
#             loopback (127.0.0.1; mac and kajo), bonjour (its _kajo-dev._tcp name)
#   sessions  at most this many sessions, one after another, while the
#             target's window has room (LIMIT seconds from its start, default
#             14); 0: the target serves with no client (the control row)
#   key=value the serving launch's (seconds=20 warmup=1 by default)
#
# Results: <outdir>/serve-<tag>.txt (the target's result line: frames and
# what it served), <outdir>/client-<tag>.txt (one line per session), the
# files the sessions wrote in <outdir>/proj-<tag>. The token goes from the
# target to a targets file of mode 0600 (the phone's: copied from its
# Application Support, as the owner would read it off the screen) and from
# there into the client shell's memory; it is never printed. PORT (47100),
# DD and TIMEOUT override.
set -uo pipefail
root=${0:A:h:h}
serve=${1:?serve} out=${2:?outdir} tag=${3:?tag} scenario=${4:?scenario} form=${5:?form} n=${6:?sessions}
shift 6
port=${PORT:-47100}
mkdir -p $out/proj-$tag
targets=$out/targets-$tag
tok=$out/tok-$tag
mkdir -p $tok && chmod 700 $tok
rm -f $tok/*(N) $targets
args=(seconds=20 warmup=1 "$@")
case $serve in
  mac)
    TIMEOUT=${TIMEOUT:-200} $root/scripts/mac-shell.sh run $out/serve-$tag.txt mode=serve scenario=$scenario \
      protocol=tcp:$port tokendir=$tok bonjour=kajo-$tag tag=$tag $args &
    spid=$!
    log=$out/serve-$tag-files/last.out
    for i in {1..150}; do [[ -s $tok/kajo-pairing-token ]] && grep -q "^serving=tcp" $log 2>/dev/null && break; sleep 0.2; done
    token=$(cat $tok/kajo-pairing-token 2>/dev/null) ;;
  device)
    $root/scripts/device.sh serve $out/serve-$tag.txt scenario=$scenario protocol=tcp:$port tag=$tag $args &
    spid=$!
    log=$out/serve-$tag-console.log
    for i in {1..300}; do grep -q "^serving=tcp" $log 2>/dev/null && break; sleep 0.2; done
    $root/scripts/device.sh token $targets || { print "remote-session: no token from the phone"; }
    token=$(awk -F'\t' '{print $3}' $targets 2>/dev/null) ;;
  kajo)
    swift build -c release --package-path $root --product kajo > /dev/null || exit 1
    kajo=$(swift build -c release --package-path $root --show-bin-path)/kajo
    [[ -f $out/shell.img ]] || $kajo build-image -o $out/shell.img $root/kernel $root/apps/Shared/smalltalk > /dev/null
    gtimeout ${TIMEOUT:-200} $kajo run $out/shell.img --protocol tcp:$port --name "kajo-$tag" > $tok/out 2> $out/serve-$tag.err &
    spid=$!
    for i in {1..100}; do grep -q token $tok/out 2>/dev/null && break; sleep 0.2; done
    token=$(sed -n 's/^kajo: token //p' $tok/out) ;;
  *) print "remote-session: serve is device, mac or kajo"; exit 2 ;;
esac
[[ -n ${token:-} ]] || { print "remote-session: the target did not serve"; kill $spid 2>/dev/null; exit 1; }
case $form in
  lan)
    if [[ $serve == device ]]; then
      host=$(sed -n 's/^serving=tcp .*addresses=\([^, ]*\).*/\1/p' $log | head -1)
    else
      host=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1)
    fi
    [[ $host == *:* ]] && addr="tcp://[$host]:$port" || addr="tcp://$host:$port" ;;
  loopback) addr="tcp://127.0.0.1:$port" ;;
  bonjour)
    name="kajo-$tag"
    if [[ $serve == device ]]; then
      for i in {1..10}; do
        name=$(gtimeout 3 dns-sd -B _kajo-dev._tcp local 2>/dev/null | awk '/Add/ && /_kajo-dev/ {n=""; for (i=7;i<=NF;i++) n=n (i>7?" ":"") $i; print n; exit}')
        [[ -n $name ]] && break
      done
    fi
    addr="bonjour:$name" ;;
  *) print "remote-session: form is lan, loopback or bonjour"; kill $spid 2>/dev/null; exit 2 ;;
esac
(umask 077; printf 'target\t%s\t%s\n' "$addr" "$token" > $targets)
start=$(date +%s)
for (( k = 1; k <= n; k++ )); do
  (( $(date +%s) - start < ${LIMIT:-14} )) || break
  kill -0 $spid 2>/dev/null || break
  TIMEOUT=${TIMEOUT:-200} $root/scripts/mac-shell.sh run $out/client-$tag.txt mode=devsession classes=0 target=target \
    targets=$targets project=$out/proj-$tag tag=$tag-$k form=$form serve=$serve
done
if [[ $serve == kajo ]]; then kill $spid 2>/dev/null; fi
wait $spid 2>/dev/null
rm -rf $tok
print "remote-session $tag: $addr, $(grep -c 'mode=devsession' $out/client-$tag.txt 2>/dev/null || print 0) sessions"
