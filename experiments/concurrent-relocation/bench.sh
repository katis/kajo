#!/usr/bin/env bash
# Build everything, run the kernel matrix, the survivor-size extras, the
# AppKit scenarios and the verifier scenario runs, print the tables
# RESULTS.md uses (SPEC.md "Headless matrix", "Scenarios").
#
# Kernel matrix: arith fib sends ivars storeheavy alloc churn survivors5
#   survivors30 oldheap64 oldheap256 oldheap512 fragment x 1, 8 workers x
#   configurations, RUNS (5) interleaved runs, 4 MiB nurseries:
#     stw    KAJO_GC=stw, N = 1 (checksum reference)
#     adr6   concurrent marking, N = 1, no relocation (ADR 0006)
#     n2     N = 2
#     n4     N = 4
#     r25 r50 r75   N = 2, relocation threshold 25, 50, 75 percent
#     ragg   N = 2, relocation of every live block, cycles back to back
#     nops   -DNO_POST_STORE build, adr6 configuration
#   Alignment control: arith fib sends ivars storeheavy also run adr6 and
#   nops in align32 builds (-align-all-nofallthru-blocks=5).
#   Old space 64 MiB; oldheapN 2 N + 64 MiB; fragment 256 MiB.
# Extras (RUNS runs, alloc, 8 workers): survivor halves of 1 and 1.5 MiB in
#   the 4 MiB nursery at N = 2; 16 MiB nurseries at N = 1 and N = 2.
# Scenarios: R0 R1 R2 R3 R4 R5 R5n R6, SRUNS (3) runs x 10 s, median run by
#   missed frames then max gap. Then R4 and R3 once each with --verify.
# Every pause and every cycle of every run is appended to bench-raw-pauses.txt.
#
# Usage: ./bench.sh            (everything)
#        PARTS="kernels" RUNS=1 KERNELS="churn" ./bench.sh
#        PARTS="scenarios" SCENARIOS="R0 R1" ./bench.sh
#        PARTS="report" ./bench.sh    (tables only, from the raw files)
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
RUNS=${RUNS:-5}
SRUNS=${SRUNS:-3}
SECONDS_PER=${SECONDS_PER:-10}
PARTS=${PARTS:-"build kernels extras scenarios verify"}
KERNELS=${KERNELS:-"arith fib sends ivars storeheavy alloc churn survivors5 survivors30 oldheap64 oldheap256 oldheap512 fragment"}
SCENARIOS=${SCENARIOS:-"R0 R1 R2 R3 R4 R5 R5n R6"}
KRAW=${KRAW:-"$HERE/bench-raw-kernels.txt"}
SRAW=${SRAW:-"$HERE/bench-raw-scenarios.txt"}
PRAW=${PRAW:-"$HERE/bench-raw-pauses.txt"}
ALIGN=(-Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5)
S="$HERE/swift"
O="$S/.build/release/cr-bench"
NP="$S/.build/nops/release/cr-bench"
OA="$S/.build/align/release/cr-bench"
NPA="$S/.build/nops-align/release/cr-bench"

has() { [[ " $PARTS " == *" $1 "* ]]; }

if has build; then
    echo "== builds"
    swift build -c release --package-path "$S" --product cr-bench > /dev/null
    swift build -c release --package-path "$S" --product kajo-ui > /dev/null
    swift build -c release --package-path "$S" --product cr-bench --scratch-path "$S/.build/nops" -Xswiftc -DNO_POST_STORE > /dev/null
    swift build -c release --package-path "$S" --product cr-bench --scratch-path "$S/.build/align" "${ALIGN[@]}" > /dev/null
    swift build -c release --package-path "$S" --product cr-bench --scratch-path "$S/.build/nops-align" -Xswiftc -DNO_POST_STORE "${ALIGN[@]}" > /dev/null
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
    if out=$(env KAJO_NURSERY_KB=4096 "$@" KAJO_TAG="$tag" KAJO_GC_DUMP="$PRAW" "$bin" kernel "$k" "$n" 2>/dev/null); then
        echo "$tag $out" >> "$KRAW"
    else
        echo "$tag kernel=$k workers=$n FAILED=1" >> "$KRAW"
    fi
}

compute() { [[ " arith fib sends ivars storeheavy " == *" $1 "* ]]; }

if has kernels; then
    echo "== kernels: [$KERNELS] x 1,8 workers x stw adr6 n2 n4 r25 r50 r75 ragg nops (+align32), $RUNS runs"
    header > "$KRAW"
    : > "$PRAW"
    for run in $(seq 1 "$RUNS"); do
        for k in $KERNELS; do
            for n in 1 8; do
                one stw O "$O" "$k" "$n" "$run" KAJO_GC=stw
                one adr6 O "$O" "$k" "$n" "$run" KAJO_GC=cm
                one n2 O "$O" "$k" "$n" "$run" KAJO_GC=cm KAJO_AGE=2
                one n4 O "$O" "$k" "$n" "$run" KAJO_GC=cm KAJO_AGE=4
                for t in 25 50 75; do one "r$t" O "$O" "$k" "$n" "$run" KAJO_GC=cm KAJO_AGE=2 KAJO_RELOC=$t; done
                one ragg O "$O" "$k" "$n" "$run" KAJO_GC=cm KAJO_AGE=2 KAJO_RELOC=all KAJO_CM_FORCE=1
                one nops O "$NP" "$k" "$n" "$run" KAJO_GC=cm
                if compute "$k"; then
                    one adr6 align32 "$OA" "$k" "$n" "$run" KAJO_GC=cm
                    one nops align32 "$NPA" "$k" "$n" "$run" KAJO_GC=cm
                fi
            done
        done
        echo "   run $run/$RUNS done"
    done
fi

if has extras; then
    echo "== extras: alloc 8 workers, survivor and nursery sizes, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        one n2-s1024 O "$O" alloc 8 "$run" KAJO_GC=cm KAJO_AGE=2 KAJO_SURVIVOR_KB=1024
        one n2-s1536 O "$O" alloc 8 "$run" KAJO_GC=cm KAJO_AGE=2 KAJO_SURVIVOR_KB=1536
        one adr6-nur16 O "$O" alloc 8 "$run" KAJO_GC=cm KAJO_NURSERY_KB=16384
        one n2-nur16 O "$O" alloc 8 "$run" KAJO_GC=cm KAJO_AGE=2 KAJO_NURSERY_KB=16384
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
    echo "== verifier scenario runs: R4, R3 with --verify"
    for sc in R4 R3; do
        KAJO_TAG="cfg=verify build=O run=1" \
            "$S/.build/release/kajo-ui" "$sc" --seconds "$SECONDS_PER" --run 1 --verify --out "$SRAW" \
            > /dev/null 2>> "$HERE/swift/.build/kajo-ui-stderr.txt" || echo "   $sc verify FAILED"
        sleep 1
    done
fi

python3 "$HERE/report.py" "$KRAW" "$SRAW" "$PRAW"
