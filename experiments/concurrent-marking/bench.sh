#!/usr/bin/env bash
# Build everything, run the kernel matrix, the threshold and marker-QoS
# extras, the AppKit scenarios and the verifier scenario runs, print the
# tables RESULTS.md uses (SPEC.md "Headless matrix", "Scenarios").
#
# Kernel matrix: arith fib sends ivars alloc churn survivors5 survivors30
#   oldheap64 oldheap256 oldheap512 x 1, 8 workers x configurations, RUNS (5)
#   interleaved runs, 4 MiB nurseries. Configurations:
#     nomark  -DNO_MARK_BARRIER build, stop-the-world full collections (ADR 0005)
#     stw     barrier build, stop-the-world (the SATB fast path runs, never fires)
#     cm      barrier build, concurrent marking, 1 marker
#     cm2     2 markers (alloc and the oldheap kernels)
#     force   concurrent marking with the marking flag always on
#   Alignment control: arith fib sends ivars churn also run nomark and stw in
#   an align32 build (-align-all-nofallthru-blocks=5).
#   Old space 64 MiB; oldheapN: 2 N + 64 MiB.
# Extras (5 runs, 8 workers, cm): alloc and survivors30 at thresholds 20 30
#   40 50 percent; alloc and oldheap256 with the marker at QoS user-initiated.
# Heap (added after the first full run, 5 runs, 8 workers): alloc with a
#   256 MiB old space, stw, cm, cm with the marker at QoS user-initiated.
# Scenarios: C0..C6, SRUNS (3) runs x 10 s, median run by missed frames then
#   max gap. Then C2 and C4 once each with the mark-set verifier on.
# Every pause and every cycle of every run is appended to bench-raw-pauses.txt.
#
# Usage: ./bench.sh            (everything)
#        PARTS="kernels" RUNS=1 KERNELS="churn" ./bench.sh
#        PARTS="scenarios" SCENARIOS="C0 C2" ./bench.sh
#        PARTS="report" ./bench.sh    (tables only, from the raw files)
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
RUNS=${RUNS:-5}
SRUNS=${SRUNS:-3}
SECONDS_PER=${SECONDS_PER:-10}
PARTS=${PARTS:-"build kernels extras heap scenarios verify"}
KERNELS=${KERNELS:-"arith fib sends ivars alloc churn survivors5 survivors30 oldheap64 oldheap256 oldheap512"}
SCENARIOS=${SCENARIOS:-"C0 C1 C2 C3 C4 C5 C6"}
KRAW=${KRAW:-"$HERE/bench-raw-kernels.txt"}
SRAW=${SRAW:-"$HERE/bench-raw-scenarios.txt"}
PRAW=${PRAW:-"$HERE/bench-raw-pauses.txt"}
ALIGN=(-Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5)
S="$HERE/swift"
O="$S/.build/release/cm-bench"
NM="$S/.build/nomark/release/cm-bench"
OA="$S/.build/align/release/cm-bench"
NMA="$S/.build/nomark-align/release/cm-bench"

has() { [[ " $PARTS " == *" $1 "* ]]; }

if has build; then
    echo "== builds"
    swift build -c release --package-path "$S" --product cm-bench > /dev/null
    swift build -c release --package-path "$S" --product kajo-ui > /dev/null
    swift build -c release --package-path "$S" --product cm-bench --scratch-path "$S/.build/nomark" -Xswiftc -DNO_MARK_BARRIER > /dev/null
    swift build -c release --package-path "$S" --product cm-bench --scratch-path "$S/.build/align" "${ALIGN[@]}" > /dev/null
    swift build -c release --package-path "$S" --product cm-bench --scratch-path "$S/.build/nomark-align" -Xswiftc -DNO_MARK_BARRIER "${ALIGN[@]}" > /dev/null
fi

header() {
    echo "# machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.perflevel0.physicalcpu) P-cores + $(sysctl -n hw.perflevel1.physicalcpu) E-cores, macOS $(sw_vers -productVersion), no pinning"
    echo "# $(swift --version 2>&1 | head -1)"
}

# one kernel run: cfg build binary kernel workers run [env...]
one() {
    local cfg=$1 build=$2 bin=$3 k=$4 n=$5 run=$6; shift 6
    local tag="cfg=$cfg build=$build run=$run"
    local out
    if out=$(env "$@" KAJO_NURSERY_KB=4096 KAJO_TAG="$tag" KAJO_GC_DUMP="$PRAW" "$bin" kernel "$k" "$n" 2>/dev/null); then
        echo "$tag $out" >> "$KRAW"
    else
        echo "$tag kernel=$k workers=$n FAILED=1" >> "$KRAW"
    fi
}

compute() { [[ " arith fib sends ivars churn " == *" $1 "* ]]; }
twomarkers() { [[ "$1" == alloc || "$1" == oldheap* ]]; }

if has kernels; then
    echo "== kernels: [$KERNELS] x 1,8 workers x nomark stw cm cm2 force (+align32), $RUNS runs"
    header > "$KRAW"
    : > "$PRAW"
    for run in $(seq 1 "$RUNS"); do
        for k in $KERNELS; do
            for n in 1 8; do
                one nomark O "$NM" "$k" "$n" "$run" KAJO_GC=stw
                one stw O "$O" "$k" "$n" "$run" KAJO_GC=stw
                one cm O "$O" "$k" "$n" "$run" KAJO_GC=cm
                if twomarkers "$k"; then one cm2 O "$O" "$k" "$n" "$run" KAJO_GC=cm KAJO_CM_MARKERS=2; fi
                one force O "$O" "$k" "$n" "$run" KAJO_GC=cm KAJO_CM_FORCE=1
                if compute "$k"; then
                    one nomark align32 "$NMA" "$k" "$n" "$run" KAJO_GC=stw
                    one stw align32 "$OA" "$k" "$n" "$run" KAJO_GC=stw
                fi
            done
        done
        echo "   run $run/$RUNS done"
    done
fi

if has extras; then
    echo "== extras: thresholds, marker QoS, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        for k in alloc survivors30; do
            for t in 20 30 40 50; do one "cm-t$t" O "$O" "$k" 8 "$run" KAJO_GC=cm KAJO_CM_THRESHOLD=$t; done
        done
        for k in alloc oldheap256; do one cm-qoshigh O "$O" "$k" 8 "$run" KAJO_GC=cm KAJO_CM_QOS=high; done
    done
fi

if has heap; then
    echo "== heap: alloc, 8 workers, 256 MiB old space, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        one stw-h256 O "$O" alloc 8 "$run" KAJO_GC=stw KAJO_HEAP_MB=256
        one cm-h256 O "$O" alloc 8 "$run" KAJO_GC=cm KAJO_HEAP_MB=256
        one cm-qoshigh-h256 O "$O" alloc 8 "$run" KAJO_GC=cm KAJO_HEAP_MB=256 KAJO_CM_QOS=high
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

if has verify; then
    echo "== verifier scenario runs: C2, C4 with --verify"
    for sc in C2 C4; do
        KAJO_TAG="cfg=verify build=O run=1" \
            "$S/.build/release/kajo-ui" "$sc" --seconds "$SECONDS_PER" --run 1 --verify --out "$SRAW" \
            > /dev/null 2>> "$HERE/swift/.build/kajo-ui-stderr.txt" || echo "   $sc verify FAILED"
        sleep 1
    done
fi

python3 "$HERE/report.py" "$KRAW" "$SRAW" "$PRAW"
