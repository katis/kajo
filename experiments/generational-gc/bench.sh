#!/usr/bin/env bash
# Build everything, run the kernel matrix, the pause-scaling sweep and the
# AppKit scenarios, print the tables RESULTS.md uses.
#
# Kernel matrix: arith fib sends ivars alloc churn survivors5 survivors30
#   x 1, 8 workers x configurations x builds, RUNS (5) interleaved runs.
#   Configurations (old space 64 MiB):
#     nobar  -DNO_BARRIER build: no write barrier, non-generational
#     bar0   barrier compiled in, nursery 0: non-generational, barrier never fires
#     g1 g4 g16  barrier, 1 / 4 / 16 MiB nursery per worker
#   Builds: O (-c release) and align32 (O + -align-all-nofallthru-blocks=5).
#   A run that dies (out of memory) is recorded as FAILED.
# Extra: survivors5, 8 workers, nobar with a 512 MiB old space (see RESULTS.md).
# Scaling: alloc churn survivors30 at g4, O build, 1 2 4 8 workers, RUNS runs.
# Scenarios: G0..G5, SRUNS (3) runs x 10 s; the median run (by missed frames,
#   then max gap) is reported.
# Every pause of every run is appended to bench-raw-pauses.txt; pause
# distributions are pooled over the runs of a configuration.
#
# Usage: ./bench.sh            (everything)
#        PARTS="kernels" RUNS=1 KERNELS="churn" ./bench.sh
#        PARTS="scenarios" SCENARIOS="G0 G2" ./bench.sh
#        PARTS="report" ./bench.sh    (tables only, from the raw files)
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
RUNS=${RUNS:-5}
SRUNS=${SRUNS:-3}
SECONDS_PER=${SECONDS_PER:-10}
PARTS=${PARTS:-"build kernels scaling scenarios"}
KERNELS=${KERNELS:-"arith fib sends ivars alloc churn survivors5 survivors30"}
SCENARIOS=${SCENARIOS:-"G0 G1 G2 G3 G4 G5"}
KRAW=${KRAW:-"$HERE/bench-raw-kernels.txt"}
SRAW=${SRAW:-"$HERE/bench-raw-scenarios.txt"}
PRAW=${PRAW:-"$HERE/bench-raw-pauses.txt"}
ALIGN=(-Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5)
S="$HERE/swift"

has() { [[ " $PARTS " == *" $1 "* ]]; }

if has build; then
    echo "== builds"
    swift build -c release --package-path "$S" --product ggc-bench
    swift build -c release --package-path "$S" --product kajo-ui
    swift build -c release --package-path "$S" --product ggc-bench --scratch-path "$S/.build/nobar" -Xswiftc -DNO_BARRIER
    swift build -c release --package-path "$S" --product ggc-bench --scratch-path "$S/.build/align" "${ALIGN[@]}"
    swift build -c release --package-path "$S" --product ggc-bench --scratch-path "$S/.build/nobar-align" -Xswiftc -DNO_BARRIER "${ALIGN[@]}"
fi

# name|build|nursery KiB|binary
CONFIGS=(
    "nobar|O|0|$S/.build/nobar/release/ggc-bench"
    "bar0|O|0|$S/.build/release/ggc-bench"
    "g1|O|1024|$S/.build/release/ggc-bench"
    "g4|O|4096|$S/.build/release/ggc-bench"
    "g16|O|16384|$S/.build/release/ggc-bench"
    "nobar|align32|0|$S/.build/nobar-align/release/ggc-bench"
    "bar0|align32|0|$S/.build/align/release/ggc-bench"
    "g1|align32|1024|$S/.build/align/release/ggc-bench"
    "g4|align32|4096|$S/.build/align/release/ggc-bench"
    "g16|align32|16384|$S/.build/align/release/ggc-bench"
)

header() {
    echo "# machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.perflevel0.physicalcpu) P-cores + $(sysctl -n hw.perflevel1.physicalcpu) E-cores, macOS $(sw_vers -productVersion), no pinning"
    echo "# $(swift --version 2>&1 | head -1)"
}

# one kernel run: cfg build nursery binary kernel workers run [env...]
one() {
    local cfg=$1 build=$2 nb=$3 bin=$4 k=$5 n=$6 run=$7; shift 7
    local tag="cfg=$cfg build=$build run=$run"
    local out
    if out=$(env "$@" KAJO_NURSERY_KB="$nb" KAJO_TAG="$tag" KAJO_GC_DUMP="$PRAW" "$bin" kernel "$k" "$n" 2>/dev/null); then
        echo "$tag $out" >> "$KRAW"
    else
        echo "$tag kernel=$k workers=$n nursery_kb=$nb FAILED=1" >> "$KRAW"
    fi
}

if has kernels; then
    echo "== kernels: [$KERNELS] x 1,8 workers x nobar bar0 g1 g4 g16 x O align32, $RUNS runs"
    header > "$KRAW"
    : > "$PRAW"
    for run in $(seq 1 "$RUNS"); do
        for k in $KERNELS; do
            for n in 1 8; do
                for c in "${CONFIGS[@]}"; do
                    IFS='|' read -r cfg build nb bin <<< "$c"
                    one "$cfg" "$build" "$nb" "$bin" "$k" "$n" "$run" KAJO_HEAP_MB=64
                done
            done
        done
        one nobar512 O 0 "$S/.build/nobar/release/ggc-bench" survivors5 8 "$run" KAJO_HEAP_MB=512
        echo "   run $run/$RUNS done"
    done
fi

if has scaling; then
    echo "== pause scaling: alloc churn survivors30 x 1 2 4 8 workers, g4, O, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        for k in alloc churn survivors30; do
            for n in 1 2 4 8; do
                one scale O 4096 "$S/.build/release/ggc-bench" "$k" "$n" "$run" KAJO_HEAP_MB=64
            done
        done
    done
fi

if has scenarios; then
    echo "== scenarios: [$SCENARIOS], $SRUNS runs x ${SECONDS_PER} s (a window will appear)"
    header > "$SRAW"
    for run in $(seq 1 "$SRUNS"); do
        for sc in $SCENARIOS; do
            KAJO_TAG="cfg=scenario build=O run=$run" KAJO_GC_DUMP="$PRAW" \
                "$S/.build/release/kajo-ui" "$sc" --seconds "$SECONDS_PER" --run "$run" --out "$SRAW" \
                > /dev/null 2>> "$HERE/swift/.build/kajo-ui-stderr.txt" || echo "   $sc run $run FAILED"
            sleep 1
        done
        echo "   run $run/$SRUNS done"
    done
fi

python3 "$HERE/report.py" "$KRAW" "$SRAW" "$PRAW"
