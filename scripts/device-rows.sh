#!/bin/zsh
# The device rows of a gate run (docs/modules/gate-tiers.md): builds and
# installs the iOS shell on one attached device through scripts/device.sh,
# runs scripts/shell-matrix.sh device on it, and writes the report
# (report.md) and the bar's tabulation over every raw row (stdout).
#
#   scripts/device-rows.sh <udid> <outdir> [parts]      (RUNS as shell-matrix.sh)
#
# A device build never waits on a prompt: while it runs, any codesign
# process of this user whose CPU time stays the same for 60 s is taken to
# wait on a keychain prompt; it and the build are killed, the fact is
# written, and the script exits 3 without device rows (AGENTS.md: a gate
# that waits on a prompt is a blocked gate). Exit status: 0 rows written
# and no launch failed, 1 a launch failed or the build failed, 3 skipped.
set -uo pipefail
root=${0:A:h:h}
udid=${1:?<udid> <outdir> [parts]}
out=${2:?<udid> <outdir> [parts]}
parts=${3:-}
tmp=${TMPDIR:-/tmp}
case $udid in
  00008110-001855C63642801E) dd=$tmp/kajo-shell-ios ;;
  00008027-0012592C0185002E) dd=$tmp/kajo-shell-ipad ;;
  *) dd=$tmp/kajo-shell-ios-$udid ;;
esac
export DEVICE=$udid DD=${DD:-$dd}
mkdir -p $out

kill_tree() { local p; for p in $(pgrep -P $1 2>/dev/null); do kill_tree $p; done; kill -TERM $1 2>/dev/null }

print "device-rows: $udid, DerivedData $DD, $(date '+%F %T')"
$root/scripts/device.sh build > $out/build.txt 2>&1 &
b=$!
trap 'kill_tree $b; exit 130' INT TERM
typeset -A cpu since
prompt=0 t0=$(date +%s)
while kill -0 $b 2>/dev/null; do
  for p in $(pgrep -x -U $(id -u) codesign); do
    c=$(ps -o time= -p $p 2>/dev/null | tr -d ' ')
    [[ -n $c ]] || continue
    if [[ ${cpu[$p]:-} != $c ]]; then cpu[$p]=$c; since[$p]=$(date +%s)
    elif (( $(date +%s) - since[$p] >= 60 )); then
      print "device-rows: codesign $p sat at 0 percent CPU for 60 s (cpu time $c): a keychain prompt? killed it and the build; device rows skipped"
      kill -TERM $p 2>/dev/null; kill_tree $b; prompt=1; break 2
    fi
  done
  (( $(date +%s) - t0 > 2700 )) && { print "device-rows: the build ran past 2700 s; killed"; kill_tree $b; break }
  sleep 5
done
wait $b
rc=$?
trap - INT TERM
cat $out/build.txt
(( prompt )) && exit 3
(( rc )) && { print "device-rows: build failed rc=$rc"; exit 1 }
# Every step's status counts (the review fixes, part 2, item 11).
status=0
if [[ -n $parts ]]; then $root/scripts/shell-matrix.sh device $out "$parts" || status=1; else $root/scripts/shell-matrix.sh device $out || status=1; fi
$root/scripts/shell-report.py $out > $out/report.md || status=1
$root/scripts/shell-report.py --bar $out || status=1
exit $status
