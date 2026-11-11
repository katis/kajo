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
# SECONDS_ (10) override; EXTRA_ARGS adds launch arguments (AOT 1: native=1).
#
# The first-launch follow-up (docs/modules/first-launch.md): before its first
# row the matrix runs one idle launch of the shell, the warm-up, into
# warmup.txt (tag=warmup); it is not a row (shell-report.py prints its
# numbers on a line of their own, never in a table or the bar). WARMUP=0
# leaves it out.
set -uo pipefail
root=${0:A:h:h}
target=${1:?mac|device}
out=${2:?outdir}
parts=${3:-"drift golden scenarios events hog drift"}
RUNS=${RUNS:-3}
SECS=${SECONDS_:-10}
mkdir -p $out
# AOT 1: EXTRA_ARGS (for example native=1) is added to every launch.
if [[ $target == mac ]]; then
  W=${WORKERS:-7}; one() { $root/scripts/mac-shell.sh run "$@" ${=EXTRA_ARGS:-} }
  GW=(1 2 6)
else
  W=${WORKERS:-5}; one() { $root/scripts/device.sh run "$@" ${=EXTRA_ARGS:-} }
  GW=(1 2 6)
fi
drifted=0
if [[ ${WARMUP:-1} == 1 ]]; then
  one $out/warmup.txt mode=scenario scenario=idle young=offload workers=$W seconds=$SECS tag=warmup run=1
fi
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
            one $out/scenarios.txt mode=scenario scenario=$s young=$y workers=$W seconds=$SECS run=$run
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
# Reaching the end is success: each launch's failure is a FAILED row the bar
# counts; a status other than 0 means the script itself died (the review
# fixes, part 2, item 11: the gates read it).
exit 0
