#!/usr/bin/env bash
# Mac matrix (SPEC.md; DESIGN.md "Part 1", "Part 3"). One configuration per
# process, RUNS interleaved runs, raw lines appended to results/mac-*.txt.
#
#   part1   chase-bench: [MODES] x [SIZES] MB x 1, 8 threads
#   hop     el-bench walkN, walkbuildN x A B C L x N=20..23, 1 worker
#   orig    el-bench walk, walkbuild (object-representation's 2^22 kernels) x A B C, 1 worker
#   compact el-bench walkcompactN, walkcompactbuildN x A B L x N=22,23
#   mark    el-bench walkmarkN x A B L x N=22,23
#   sends   el-bench sends, ivars x A B L x 1, 6 workers
#   qos     el-bench walk22, walkbuild22 x A B, workers at user-initiated vs
#           default attributes (KAJO_WORKER_QOS=inherit), 3 runs
#   lcg     chase-bench chase dsep dlocal x 64, 256 MB x random, LCG order, 3 runs
#   work    chase-bench chase dsep dlocal x [WSIZES] x work 0, WORK, 1 thread,
#           3 runs (added after part1; see RESULTS.md)
#
# Usage: ./bench.sh                       (everything)
#        PARTS="part1" RUNS=1 ./bench.sh
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
RUNS=${RUNS:-5}
PARTS=${PARTS:-"build part1 hop orig compact mark sends qos work lcg report"}
WSIZES=${WSIZES:-"16 32 64 96 128 192 256 512"}
WORK=${WORK:-64}
MODES=${MODES:-"chase dsep dlocal dhalf spread"}
SIZES=${SIZES:-"1 2 4 8 16 24 32 48 64 96 128 192 256 512 1024"}
MT=${MT:-8}            # threads for the multi-threaded chase
MTCAP=${MTCAP:-512}    # per-thread MB cap when multi-threaded
R="$HERE/results"
B="$HERE/swift/.build/release"
mkdir -p "$R"
has() { [[ " $PARTS " == *" $1 "* ]]; }
hdr() { # file
    [[ -s "$1" ]] && return
    echo "# machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.perflevel0.physicalcpu) P + $(sysctl -n hw.perflevel1.physicalcpu) E, $(($(sysctl -n hw.memsize) >> 30)) GB, $(sw_vers -productVersion)" >> "$1"
    echo "# $(swift --version 2>&1 | head -1)" >> "$1"
}

if has build; then
    echo "== release build (-O, whole module)"
    swift build -c release --package-path swift --product chase-bench > /dev/null
    swift build -c release --package-path swift --product el-bench > /dev/null
fi

if has part1; then
    O="$R/mac-part1.txt"; hdr "$O"
    echo "== part1: [$MODES] x [$SIZES] x 1, $MT threads, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        for s in $SIZES; do
            for m in $MODES; do
                echo "run=$run $("$B/chase-bench" "$m" "$s" 1)" >> "$O"
                if (( s <= MTCAP )); then echo "run=$run $("$B/chase-bench" "$m" "$s" "$MT")" >> "$O"; fi
            done
        done
        echo "   run $run/$RUNS done"
    done
fi

el() { # out tag variant kernel workers run
    echo "run=$6 tag=$2 $("$B/el-bench" "$3" "$4" "$5")" >> "$1"
}

if has hop; then
    O="$R/mac-hop.txt"; hdr "$O"
    echo "== hop: walkN, walkbuildN x A B C L x 20..23, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        for n in 20 21 22 23; do
            for k in walk$n walkbuild$n; do
                for v in A B C L; do el "$O" matrix $v $k 1 $run; done
            done
        done
        echo "   run $run/$RUNS done"
    done
fi

if has orig; then
    O="$R/mac-orig.txt"; hdr "$O"
    echo "== orig: walk, walkbuild x A B C, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        for k in walk walkbuild; do for v in A B C; do el "$O" orig $v $k 1 $run; done; done
    done
fi

if has compact; then
    O="$R/mac-compact.txt"; hdr "$O"
    echo "== compact: walkcompactN, walkcompactbuildN x A B L x 22, 23, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        for n in 22 23; do
            for k in walkcompact$n walkcompactbuild$n; do
                for v in A B L; do el "$O" matrix $v $k 1 $run; done
            done
        done
        echo "   run $run/$RUNS done"
    done
fi

if has mark; then
    O="$R/mac-mark.txt"; hdr "$O"
    echo "== mark: walkmarkN x A B L x 22, 23, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        for n in 22 23; do for v in A B L; do el "$O" matrix $v walkmark$n 1 $run; done; done
    done
fi

if has sends; then
    O="$R/mac-sends.txt"; hdr "$O"
    echo "== sends, ivars x A B L x 1, 6 workers, $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        for k in sends ivars; do for w in 1 6; do for v in A B L; do el "$O" matrix $v $k $w $run; done; done; done
    done
fi

if has qos; then
    O="$R/mac-qos.txt"; hdr "$O"
    echo "== qos: walk22, walkbuild22 x A B x user-initiated, inherit; 3 runs"
    for run in 1 2 3; do
        for k in walk22 walkbuild22; do
            for v in A B; do
                el "$O" qos-ui $v $k 1 $run
                echo "run=$run tag=qos-inherit $(KAJO_WORKER_QOS=inherit "$B/el-bench" $v $k 1)" >> "$O"
            done
        done
    done
fi

if has work; then
    O="$R/mac-work.txt"; hdr "$O"
    echo "== work: chase dsep dlocal x [$WSIZES] x work 0, $WORK; 3 runs"
    for run in 1 2 3; do
        for sz in $WSIZES; do
            for m in chase dsep dlocal; do
                for w in 0 "$WORK"; do echo "run=$run tag=work $("$B/chase-bench" $m $sz 1 $w)" >> "$O"; done
            done
        done
    done
fi

if has lcg; then
    O="$R/mac-lcg.txt"; hdr "$O"
    for run in 1 2 3; do
        for sz in 64 256; do
            for m in chase dsep dlocal; do
                for o in random lcg; do echo "run=$run tag=lcg $(KAJO_ORDER=$o "$B/chase-bench" $m $sz 1)" >> "$O"; done
            done
        done
    done
fi

if has report; then
    python3 "$HERE/report.py" "$R" > "$HERE/bench-output.txt"
    cat "$HERE/bench-output.txt"
fi
