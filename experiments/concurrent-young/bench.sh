#!/usr/bin/env bash
# Build everything, run the headless matrix, the 16 MiB nursery extras, the
# AppKit scenarios and the verifier scenario runs, print the tables
# RESULTS.md uses (SPEC.md "Headless matrix", "Scenarios").
#
# Matrix: arith fib sends ivars storeheavy alloc churn survivors5 survivors30
#   oldheap64 fragment share x 1, 8 workers x configurations, RUNS (5)
#   interleaved runs, 4 MiB nurseries, KAJO_GC=cm, N = 2:
#     orig      ../concurrent-relocation's cr-bench, unmodified (not share)
#     adr7      -DNO_YOUNG_BARRIER build, KAJO_YOUNG=stw (reference, checksums)
#     adr7b     default build, stw (barriers compiled in, local collection off)
#     local     default build, Part 1
#     offload   default build, Part 2
#     nobarrier -DNO_YOUNG_BARRIER build, local (cost only, unsound)
# Extras: alloc and survivors30 at 16 MiB nurseries, same configurations;
#   Part 3 (b): alloc survivors30 oldheap64 fragment share on 8 workers as
#   localb / offloadb (KAJO_IM=scavenge, the forced global scavenge at the
#   initial mark) against local / offload ((a), young-root scan).
# Scenarios: Y0 Y1 Y2 Y3 Y4l Y4o Y5l Y5o Y6, SRUNS (3) runs x 10 s, then Y3
#   and Y6 once each with --verify.
#
# Usage: ./bench.sh            (everything)
#        PARTS="kernels" RUNS=1 KERNELS="churn" ./bench.sh
#        PARTS="scenarios" SCENARIOS="Y0 Y1" ./bench.sh
#        PARTS="report" ./bench.sh    (tables only, from the raw files)
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
RUNS=${RUNS:-5}
SRUNS=${SRUNS:-3}
SECONDS_PER=${SECONDS_PER:-10}
PARTS=${PARTS:-"build kernels extras scenarios verify report"}
KERNELS=${KERNELS:-"arith fib sends ivars storeheavy alloc churn survivors5 survivors30 oldheap64 fragment share"}
CONFIGS=${CONFIGS:-"orig adr7 adr7b local offload nobarrier"}
SCENARIOS=${SCENARIOS:-"Y0 Y1 Y2 Y3 Y4l Y4o Y5l Y5o Y6"}
KRAW=${KRAW:-"$HERE/bench-raw-kernels.txt"}
SRAW=${SRAW:-"$HERE/bench-raw-scenarios.txt"}
PRAW=${PRAW:-"$HERE/bench-raw-pauses.txt"}
S="$HERE/swift"
O="$S/.build/release/cy-bench"
NB="$S/.build/nobarrier/release/cy-bench"
CR="$HERE/../concurrent-relocation/swift"
ORIG="$CR/.build/release/cr-bench"

has() { [[ " $PARTS " == *" $1 "* ]]; }

if has build; then
    echo "== builds"
    swift build -c release --package-path "$S" --product cy-bench > /dev/null
    swift build -c release --package-path "$S" --product kajo-ui > /dev/null
    swift build -c release --package-path "$S" --product cy-bench --scratch-path "$S/.build/nobarrier" -Xswiftc -DNO_YOUNG_BARRIER > /dev/null
    # The unmodified previous VM, built in place (its .build is ignored).
    swift build -c release --package-path "$CR" --product cr-bench > /dev/null
fi

header() {
    echo "# machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.perflevel0.physicalcpu) P-cores + $(sysctl -n hw.perflevel1.physicalcpu) E-cores, macOS $(sw_vers -productVersion), no pinning"
    echo "# $(swift --version 2>&1 | head -1)"
}

# one kernel run: cfg kernel workers run nurseryKB
one() {
    local cfg=$1 k=$2 n=$3 run=$4 nkb=$5
    local bin env=(KAJO_GC=cm KAJO_AGE=2 KAJO_NURSERY_KB=$nkb)
    case $cfg in
        orig) bin=$ORIG; [[ $k == share ]] && return 0 ;;
        adr7) bin=$NB; env+=(KAJO_YOUNG=stw) ;;
        adr7b) bin=$O; env+=(KAJO_YOUNG=stw) ;;
        local) bin=$O; env+=(KAJO_YOUNG=local) ;;
        offload) bin=$O; env+=(KAJO_YOUNG=offload) ;;
        nobarrier) bin=$NB; env+=(KAJO_YOUNG=local) ;;
        localb) bin=$O; env+=(KAJO_YOUNG=local KAJO_IM=scavenge) ;;
        offloadb) bin=$O; env+=(KAJO_YOUNG=offload KAJO_IM=scavenge) ;;
    esac
    local tag="cfg=$cfg run=$run"
    local out
    if out=$(env "${env[@]}" KAJO_TAG="$tag" KAJO_GC_DUMP="$PRAW" timeout 180 "$bin" kernel "$k" "$n" 2>/dev/null); then
        echo "$tag $out" >> "$KRAW"
    else
        echo "$tag kernel=$k workers=$n nursery_kb=$nkb FAILED=1" >> "$KRAW"
    fi
}

if has kernels; then
    echo "== kernels: [$KERNELS] x 1,8 workers x [$CONFIGS], $RUNS runs"
    header > "$KRAW"
    : > "$PRAW"
    for run in $(seq 1 "$RUNS"); do
        for k in $KERNELS; do
            for n in 1 8; do
                for c in $CONFIGS; do one "$c" "$k" "$n" "$run" 4096; done
            done
        done
        echo "   run $run/$RUNS done"
    done
fi

if has extras; then
    echo "== extras: alloc, survivors30 at 16 MiB nurseries, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        for k in alloc survivors30; do
            for n in 1 8; do
                for c in $CONFIGS; do one "$c" "$k" "$n" "$run" 16384; done
            done
        done
        for k in alloc survivors30 oldheap64 fragment share; do
            for c in localb offloadb; do one "$c" "$k" 8 "$run" 4096; done
        done
    done
fi

if has scenarios; then
    echo "== scenarios: [$SCENARIOS], $SRUNS runs x ${SECONDS_PER} s (a window will appear)"
    header > "$SRAW"
    for run in $(seq 1 "$SRUNS"); do
        for sc in $SCENARIOS; do
            KAJO_TAG="cfg=scenario run=$run" KAJO_GC_DUMP="$PRAW" \
                "$S/.build/release/kajo-ui" "$sc" --seconds "$SECONDS_PER" --run "$run" --out "$SRAW" \
                > /dev/null 2>> "$S/.build/kajo-ui-stderr.txt" || echo "   $sc run $run FAILED"
            sleep 1
        done
        echo "   run $run/$SRUNS done"
    done
fi

if has verify; then
    echo "== verifier scenario runs: Y3, Y6 with --verify"
    for sc in Y3 Y6; do
        KAJO_TAG="cfg=verify run=1" \
            "$S/.build/release/kajo-ui" "$sc" --seconds "$SECONDS_PER" --run 1 --verify --out "$SRAW" \
            > /dev/null 2>> "$S/.build/kajo-ui-stderr.txt" || echo "   $sc verify FAILED"
        sleep 1
    done
fi

if has report; then
    python3 "$HERE/report.py" "$KRAW" "$SRAW" > "$HERE/bench-output.txt"
    cat "$HERE/bench-output.txt"
fi
