#!/usr/bin/env bash
# Build, sign, install and run the device matrix on an iPhone, then pull the
# results and print the tables (DESIGN.md "Matrix").
#
#   Part A  walk walkbuild sends ivars x A B C x 1, 6 workers; compact become
#           x A B C x 6 workers (1 op + 5 fib); RUNS interleaved runs.
#   Part B  12 kernels x stw adr7 local offload x 1, 2, 6 workers, 4 MiB
#           nurseries, KAJO_GC=cm KAJO_AGE=2, RUNS interleaved runs; then the
#           QoS sub-matrix (QKERNELS x 2, 6 workers x offload with a utility
#           collector, local and offload with a user-initiated marker).
#   Part C  D0..D5, SRUNS runs x 10 s after 1 s warm-up.
#   Part A2 walk/walkbuild x A B x 1..6 workers, 3 runs (added, see below).
#   Every matrix starts and ends with DRIFT runs of its first kernel.
#
# One kernel or scenario per launch. Each result line is streamed by
# `devicectl ... --console`, prefixed here with the wall clock and appended
# to results/part-*.txt; the app also appends it to Documents/, pulled at the
# end as results/device-*.txt.
#
# Usage: ./bench-device.sh                       (everything)
#        PARTS="build A" RUNS=1 ./bench-device.sh
#        PARTS="report" ./bench-device.sh
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
DEVICE=${DEVICE:-00008150-001271502182401C}
TEAM=${TEAM:-BDN6M642M2}
BUNDLE=dev.katajamaki.kajo.devicebench
RUNS=${RUNS:-5}
SRUNS=${SRUNS:-3}
DRIFT=${DRIFT:-3}
PARTS=${PARTS:-"build A A2 B Q C pull report"}
SCRATCH=${SCRATCH:-"${TMPDIR:-/tmp}/kajo-device-measurement"}
DD="$SCRATCH/DerivedData"
APP="$DD/Build/Products/Release-iphoneos/KajoDeviceBench.app"
R="$HERE/results"
mkdir -p "$R"

AKERNELS=${AKERNELS:-"walk walkbuild sends ivars"}
AOPS=${AOPS:-"compact become"}
BKERNELS=${BKERNELS:-"alloc churn survivors5 survivors30 oldheap64 oldheap256 fragment storeheavy ivars sends fib arith"}
BCFGS=${BCFGS:-"stw adr7 local offload"}
BWORKERS=${BWORKERS:-"1 2 6"}
QKERNELS=${QKERNELS:-"alloc churn survivors5 survivors30 oldheap64 oldheap256 fragment storeheavy"}
QCFGS=${QCFGS:-"offload_ycu local_cmh offload_cmh"}
SCENARIOS=${SCENARIOS:-"D0 D1 D2 D3 D4 D5"}

has() { [[ " $PARTS " == *" $1 "* ]]; }

# launch <outfile> <tag> args...: one run, one line appended to <outfile>.
launch() {
    local out=$1 tag=$2; shift 2
    local ts line
    ts=$(date +%s)
    line=$(timeout 600 xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing \
        "$BUNDLE" "tag=$tag" "$@" 2>&1 | grep -E '^part=' | tail -1 || true)
    if [[ -z "$line" ]]; then
        line="FAILED=1 $* tag=$tag"
        echo "   FAILED: $*" >&2
    fi
    echo "at=$ts $line" >> "$out"
}

if has build; then
    echo "== build (team $TEAM)"
    if command -v xcodegen > /dev/null; then (cd app && xcodegen generate > /dev/null); fi
    xcodebuild -project app/KajoDeviceBench.xcodeproj -scheme KajoDeviceBench -configuration Release \
        -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM" build > "$SCRATCH-build.log" 2>&1 || { tail -30 "$SCRATCH-build.log"; exit 1; }
    xcrun devicectl device install app --device "$DEVICE" "$APP" > /dev/null
fi

if has A; then
    echo "== Part A: [$AKERNELS] x A B C x 1,6; [$AOPS] x 6; $RUNS runs"
    O="$R/part-a.txt"
    for i in $(seq 1 "$DRIFT"); do launch "$O" drift-start part=A variant=A kernel=walk workers=1 run=$i out=part-a.txt; done
    for run in $(seq 1 "$RUNS"); do
        for k in $AKERNELS; do
            for n in 1 6; do
                for v in A B C; do launch "$O" matrix part=A variant=$v kernel=$k workers=$n run=$run out=part-a.txt; done
            done
        done
        for k in $AOPS; do
            for v in A B C; do launch "$O" matrix part=A variant=$v kernel=$k workers=6 run=$run out=part-a.txt; done
        done
        echo "   run $run/$RUNS done"
    done
    for i in $(seq 1 "$DRIFT"); do launch "$O" drift-end part=A variant=A kernel=walk workers=1 run=$i out=part-a.txt; done
fi

if has A2; then
    # Not in DESIGN.md: walk and walkbuild at 1 to 6 workers on A and B, to
    # see how the table's traversal cost depends on the per-worker graph size
    # (2^22 / n nodes each) after Part A showed B/A of 4.5 at 1 worker and 1.1
    # at 6.
    echo "== Part A2: walk, walkbuild x A B x 1..6 workers, 3 runs"
    O="$R/part-a2.txt"
    for run in 1 2 3; do
        for n in 1 2 3 4 5 6; do
            for k in walk walkbuild; do
                for v in A B; do launch "$O" sweep part=A variant=$v kernel=$k workers=$n run=$run out=part-a2.txt; done
            done
        done
    done
fi

# Part B environment per configuration (concurrent-young/bench.sh `one`).
benv() {
    local base="KAJO_GC=cm KAJO_AGE=2 KAJO_NURSERY_KB=4096"
    case $1 in
        stw|adr7) echo "$base KAJO_YOUNG=stw" ;;
        local) echo "$base KAJO_YOUNG=local" ;;
        offload) echo "$base KAJO_YOUNG=offload" ;;
        offload_ycu) echo "$base KAJO_YOUNG=offload KAJO_YC_QOS=utility" ;;
        local_cmh) echo "$base KAJO_YOUNG=local KAJO_CM_QOS=high" ;;
        offload_cmh) echo "$base KAJO_YOUNG=offload KAJO_CM_QOS=high" ;;
    esac
}
bcfg() { case $1 in adr7) echo adr7 ;; *) echo "${1%%_*}" ;; esac; }

bone() { # out tag cfg kernel workers run
    local out=$1 tag=$2 c=$3 k=$4 n=$5 run=$6
    # shellcheck disable=SC2046
    launch "$out" "$tag" part=B cfg="$(bcfg "$c")" qcfg="$c" kernel="$k" workers="$n" run="$run" out=part-b.txt $(benv "$c")
}

if has B; then
    echo "== Part B: [$BKERNELS] x [$BCFGS] x [$BWORKERS], $RUNS runs"
    O="$R/part-b.txt"
    first=${BKERNELS%% *}
    for i in $(seq 1 "$DRIFT"); do bone "$O" drift-start stw "$first" 1 "$i"; done
    for run in $(seq 1 "$RUNS"); do
        for k in $BKERNELS; do
            for n in $BWORKERS; do
                for c in $BCFGS; do bone "$O" matrix "$c" "$k" "$n" "$run"; done
            done
        done
        echo "   run $run/$RUNS done"
    done
    for i in $(seq 1 "$DRIFT"); do bone "$O" drift-end stw "$first" 1 "$i"; done
fi

if has Q; then
    echo "== Part B QoS: [$QKERNELS] x [$QCFGS] x 2,6, $RUNS runs"
    O="$R/part-b-qos.txt"
    first=${QKERNELS%% *}
    for i in $(seq 1 "$DRIFT"); do bone "$O" drift-start stw "$first" 1 "$i"; done
    for run in $(seq 1 "$RUNS"); do
        for k in $QKERNELS; do
            for n in 2 6; do
                for c in $QCFGS; do bone "$O" qos "$c" "$k" "$n" "$run"; done
            done
        done
        echo "   run $run/$RUNS done"
    done
    for i in $(seq 1 "$DRIFT"); do bone "$O" drift-end stw "$first" 1 "$i"; done
fi

if has C; then
    echo "== Part C: [$SCENARIOS], $SRUNS runs x 10 s (keep the phone awake, app in front)"
    O="$R/part-c.txt"
    for i in $(seq 1 "$DRIFT"); do launch "$O" drift-start part=C scenario=D2 run=$i out=part-c.txt; done
    for run in $(seq 1 "$SRUNS"); do
        for s in $SCENARIOS; do launch "$O" matrix part=C scenario="$s" run="$run" out=part-c.txt; sleep 1; done
        echo "   run $run/$SRUNS done"
    done
    for i in $(seq 1 "$DRIFT"); do launch "$O" drift-end part=C scenario=D2 run=$i out=part-c.txt; done
fi

if has pull; then
    echo "== pull Documents"
    for f in part-a part-a2 part-b part-c; do
        xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE" --source "Documents/$f.txt" --destination "$R/device-$f.txt" > /dev/null 2>&1 || true
    done
fi

if has report; then
    python3 "$HERE/report.py" "$R" > "$HERE/bench-output.txt"
    cat "$HERE/bench-output.txt"
fi
