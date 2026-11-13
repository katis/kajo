#!/bin/zsh
# Gate speed (docs/modules/gate-speed.md, change 2): the fuzz gate. Builds
# the named libFuzzer targets one after another (they share .build/fuzz),
# then runs them side by side, each for the full <seconds> in its own run
# directory (.build/fuzz-run/<target>/) with its own output file
# <out>/fuzz-<target>.txt, as the four one-target gates did.
#
#   scripts/fuzz-gate.sh <seconds> <out> <target>...
#
# Prints one line per target,
#   fuzz-gate: <target> rc=<status> build=<ok|fallback|failed> runs=<n> <s>s
# which scripts/gates-lib.sh copies into gates.log. Exit 0 only when every
# target built with libFuzzer ("libFuzzer build: ok"; the fallback driver
# is never counted), ran its time and exited 0; 1 otherwise. Every run is
# bounded (gtimeout, seconds + 900) and is a child of this script, so the
# gate's timeout and gl_cleanup's tree kill reach it. KAJO_FUZZ_SH stands in
# for scripts/fuzz.sh (scripts/check-tier-test.sh).
set -uo pipefail
root=${0:A:h:h}
fz=${KAJO_FUZZ_SH:-$root/scripts/fuzz.sh}
secs=${1:?seconds} out=${2:?output directory}
shift 2
targets=("$@")
(( ${#targets} )) || { print "fuzz-gate: no targets"; exit 2 }
mkdir -p $out
typeset -A built
for t in $targets; do
  print "fuzz-gate: building $t"
  $fz --build $t > $out/fuzz-$t.txt 2>&1
  if (( $? )); then built[$t]=failed
  elif grep -q '^libFuzzer build: ok' $out/fuzz-$t.txt; then built[$t]=ok
  else built[$t]=fallback; fi
done
print "fuzz-gate: running ${targets} for ${secs}s each, side by side, from $(date '+%T')"
pids=()
# A signal (the gate's gtimeout, gl_cleanup, ^C) ends every run first: each
# run's gtimeout is in a process group of its own, which a signal to this
# script's group does not reach.
killtree() { local c; for c in $(pgrep -P $1 2>/dev/null); do killtree $c; done; kill -TERM $1 2>/dev/null }
trap 'for p in $pids; do killtree $p; done; exit 143' INT TERM HUP
for t in $targets; do
  rm -f $out/.fuzz-$t.end
  [[ ${built[$t]} == failed ]] && continue
  ( t0=$(date +%s)
    gtimeout -k 30 $(( secs + 900 )) $fz --run $t $secs >> $out/fuzz-$t.txt 2>&1
    print "$? $(( $(date +%s) - t0 ))" > $out/.fuzz-$t.end ) &
  pids+=($!)
done
for p in $pids; do wait $p; done
fail=0
for t in $targets; do
  rc=build s=0
  [[ -r $out/.fuzz-$t.end ]] && read -r rc s < $out/.fuzz-$t.end
  rm -f $out/.fuzz-$t.end
  runs=$(grep -oE 'stat::number_of_executed_units: [0-9]+' $out/fuzz-$t.txt | tail -1 | grep -oE '[0-9]+$')
  print "fuzz-gate: $t rc=$rc build=${built[$t]} runs=${runs:-?} ${s}s"
  [[ $rc == 0 && ${built[$t]} == ok ]] || fail=1
done
exit $fail
