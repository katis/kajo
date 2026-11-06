#!/bin/zsh
# The link probe (devices investigation, 2026-11-06): the iOS shell serving
# on the iPad and the iPhone at once (and the macOS shell on this Mac as the
# control), scripts/link-probe.py timing one small request against all of
# them in the same window, and the Mac's ping to each meanwhile or alone.
#
#   scripts/link-probe.sh <outdir> <tag> <ping> <targets...>
#
#   ping     none (no ping while the probe runs), or an interval in seconds
#            (ping each target at that interval while the probe runs), or
#            only:<interval> (no probe: ping alone for the window)
#   targets  ipad, iphone, mac
#
# GAPS (30) and STEADY (15) set the probe's phases in seconds; the targets
# serve scenario=idle for their sum plus 15 s. Results in <outdir>:
# probe-<tag>.tsv (link-probe.py's lines), ping-<tag>-<target>.txt,
# serve-<tag>-<target>.txt (the target's result line, with
# served_service_*), and each device's Documents in docs-<tag>-<target>/
# (requests-<tag>-<target>.txt: the target's own time per request).
set -uo pipefail
root=${0:A:h:h}
out=${1:?outdir} tag=${2:?tag} ping=${3:?ping}
shift 3
GAPS=${GAPS:-30} STEADY=${STEADY:-15}
secs=$(( GAPS * 2 + STEADY + 15 ))
mkdir -p $out
typeset -A udid=(ipad 00008027-0012592C0185002E iphone 00008110-001855C63642801E)
typeset -A addr pids
mine=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1)
for t in $@; do
  tok=$out/tok-$tag-$t; mkdir -p $tok && chmod 700 $tok; rm -f $tok/*(N)
  targets=$out/targets-$tag-$t; rm -f $targets
  case $t in
    mac)
      TIMEOUT=300 $root/scripts/mac-shell.sh run $out/serve-$tag-$t.txt mode=serve scenario=idle protocol=tcp:47101 \
        tokendir=$tok tag=$tag-$t seconds=$secs warmup=1 &
      pids[$t]=$!
      for i in {1..150}; do [[ -s $tok/kajo-pairing-token ]] && break; sleep 0.2; done
      (umask 077; printf 'mac\ttcp://%s:47101\t%s\n' "$mine" "$(cat $tok/kajo-pairing-token 2>/dev/null)" > $targets)
      addr[$t]=$mine:47101 ;;
    ipad|iphone)
      DEVICE=$udid[$t] TIMEOUT=300 $root/scripts/device.sh serve $out/serve-$tag-$t.txt scenario=idle protocol=tcp:47100 \
        tag=$tag-$t seconds=$secs warmup=1 &
      pids[$t]=$!
      log=$out/serve-$tag-$t-console.log
      for i in {1..300}; do grep -q "^serving=tcp" $log 2>/dev/null && break; sleep 0.2; done
      DEVICE=$udid[$t] $root/scripts/device.sh token $targets by-address > /dev/null || print "link-probe: no token from $t"
      all=$(sed -n 's/^serving=tcp .*addresses=\([^ ]*\).*/\1/p' $log | head -1 | tr ',' '\n')
      host=$(print -r -- $all | grep -F "${mine%.*}." | head -1)
      addr[$t]=$host:47100 ;;
  esac
done
sleep 2
pp=()
if [[ $ping != none ]]; then
  iv=${ping#only:}
  for t in $@; do
    h=${addr[$t]%:*}
    gtimeout $(( GAPS * 2 + STEADY + 5 )) ping -i $iv --apple-time $h > $out/ping-$tag-$t.txt 2>&1 &
    pp+=($!)
  done
fi
if [[ $ping != only:* ]]; then
  specs=()
  for t in $@; do specs+=("$t=tcp://${addr[$t]}=$out/targets-$tag-$t"); done
  gtimeout $(( GAPS * 2 + STEADY + 120 )) python3 -I $root/scripts/link-probe.py $out/probe-$tag.tsv $GAPS $STEADY $specs
else
  sleep $(( GAPS * 2 + STEADY + 5 ))
fi
# every background job: the pings and the serving launches (each bounded
# by its own gtimeout)
wait
for t in $@; do
  [[ $t == mac ]] && continue
  DEVICE=$udid[$t] $root/scripts/device.sh copy $out/docs-$tag-$t
done
rm -rf $out/tok-$tag-*(N) $out/targets-$tag-*(N)
print "link-probe $tag: $(wc -l < $out/probe-$tag.tsv 2>/dev/null || print 0) requests"
