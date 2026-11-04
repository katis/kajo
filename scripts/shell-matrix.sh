#!/bin/zsh
# Module 9a's measurement matrix (docs/modules/shells.md "Measurements") on
# the Mac's display or the attached iPhone, one run per launch, RUNS runs of
# everything interleaved, the first kernel repeated at the start and the end
# (drift and thermal).
#
#   scripts/shell-matrix.sh mac|device <outdir> [parts]
#
# parts (default all): golden scenarios events hog drift. RUNS (3), WORKERS
# (background workers in the scenarios: 7 on the Mac, 5 on the phone),
# SECONDS_ (10) override.
set -uo pipefail
root=${0:A:h:h}
target=${1:?mac|device}
out=${2:?outdir}
parts=${3:-"drift golden scenarios events hog drift"}
RUNS=${RUNS:-3}
SECS=${SECONDS_:-10}
mkdir -p $out
if [[ $target == mac ]]; then
  W=${WORKERS:-7}; one() { $root/scripts/mac-shell.sh run "$@" }
  GW=(1 2 6)
else
  W=${WORKERS:-5}; one() { $root/scripts/device.sh run "$@" }
  GW=(1 2 6)
fi
drifted=0
for part in ${=parts}; do
  case $part in
    drift)
      for i in 1 2 3; do one $out/drift.txt mode=golden kind=kasm kernel=fib workers=1 tag=drift$drifted run=$i; done
      drifted=$((drifted + 1)) ;;
    golden)
      for run in $(seq $RUNS); do
        for w in $GW; do
          for k in arith fib sends alloc ivars walk storeheavy closures floats; do
            one $out/golden.txt mode=golden kind=kasm kernel=$k workers=$w run=$run
          done
          for k in sends ivars closures; do
            one $out/golden.txt mode=golden kind=st kernel=$k workers=$w run=$run
          done
        done
      done ;;
    scenarios)
      for run in $(seq $RUNS); do
        one $out/scenarios.txt mode=scenario scenario=idle young=offload workers=$W seconds=$SECS run=$run
        for s in storm ring share; do
          for y in stw local offload; do
            # The stop-the-world scavenge's promotion reserve runs out on the
            # ring at the default 600 MiB (a trap in module 4): 1024 MiB.
            heap=(); [[ $s == ring && $y == stw ]] && heap=(heap=1024)
            one $out/scenarios.txt mode=scenario scenario=$s young=$y workers=$W seconds=$SECS run=$run $heap
          done
        done
      done ;;
    events)
      for run in $(seq $RUNS); do
        one $out/events.txt mode=scenario scenario=idle young=offload events=1000 workers=$W seconds=$SECS run=$run
        one $out/events.txt mode=scenario scenario=storm young=offload events=1000 workers=$W seconds=$SECS run=$run
      done ;;
    hog)
      for run in $(seq $RUNS); do
        one $out/hog.txt mode=scenario scenario=idle young=offload hog=1 events=1000 workers=$W seconds=$SECS run=$run
        one $out/hog.txt mode=scenario scenario=idle young=offload hog=1 budget=off workers=$W seconds=$SECS run=$run
      done ;;
  esac
done
