#!/usr/bin/env bash
# Build, sign, install and run the phone matrix (device-measurement's
# pattern): one configuration per launch over devicectl, each result line
# streamed and appended to results/dev-*.txt with the launch time `at=`;
# the app also appends it to Documents/, pulled at the end as
# results/device-*.txt. Thermal state at start and end and phys_footprint
# on every line. Every matrix starts and ends with DRIFT runs of its first
# configuration; a cool-down to nominal (or fair after COOL_MAX minutes)
# precedes each matrix.
#
#   part1    chase-bench: [MODES] x [SIZES] x 1 thread; 2 and 6 threads up to
#            the per-thread cap (total under 1.5 GB)
#   hop      walkN, walkbuildN x A B C L x N=20..23, 1 worker
#   orig     object-representation's walk, walkbuild x A B C, 1 worker
#   compact  walkcompactN, walkcompactbuildN x A B L x N=22,23
#   mark     walkmarkN x A B L x N=22,23
#   sends    sends, ivars x A B L x 1, 6 workers
#   qos      walk22, walkbuild22 x A B x workers at user-initiated and at
#            the original default attributes (QoS default), 3 runs
#   work     chase, dsep, dlocal x [WSIZES] x work 0 and WORK, 1 thread, 3
#            runs (added after part1; see RESULTS.md)
#   membw    walk21/22, walkbuild21/22 x A B L, and chase dsep dlocal at 64
#            and 256 MB, each alone and with a companion thread streaming
#            through STREAM MB, 3 runs (added after hop; see RESULTS.md)
#   membw2   walk22, walkbuild22 x A B L and chase, dsep at 256 MB, alone and
#            with the companion capped at [RATES] MB/s (1 = it only spins),
#            3 runs (added after membw)
#   lcg      chase, dsep, dlocal x 64, 256 MB x random and LCG order, 3 runs
#
# Usage: ./bench-device.sh                     (everything)
#        PARTS="build hop" RUNS=1 ./bench-device.sh
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
DEVICE=${DEVICE:-00008150-001271502182401C}
TEAM=${TEAM:-BDN6M642M2}
BUNDLE=dev.katajamaki.kajo.entrylocality
RUNS=${RUNS:-5}
P1RUNS=${P1RUNS:-3}
DRIFT=${DRIFT:-2}
PARTS=${PARTS:-"build part1 hop orig compact mark sends qos work membw membw2 lcg pull report"}
STREAM=${STREAM:-64}
RATES=${RATES:-"1 250 1000 4000"}

WSIZES=${WSIZES:-"16 32 64 96 128 192 256 512"}
WORK=${WORK:-64}
MODES=${MODES:-"chase dsep dlocal dhalf spread"}
SIZES=${SIZES:-"1 2 4 8 16 24 32 48 64 96 128 192 256 512 1024"}
SCRATCH=${SCRATCH:?set SCRATCH to a scratch directory}
DD="$SCRATCH/DerivedData-el"
APP="$DD/Build/Products/Release-iphoneos/KajoEntryLocality.app"
R="$HERE/results"
mkdir -p "$R"
has() { [[ " $PARTS " == *" $1 "* ]]; }

# launch <outfile> <tag> args...: one run, one line appended to <outfile>.
launch() {
    local out=$1 tag=$2; shift 2
    local ts line
    ts=$(date +%s)
    line=$(timeout 900 xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing \
        "$BUNDLE" "tag=$tag" "$@" 2>&1 | grep -E '^part=' | tail -1 || true)
    if [[ -z "$line" ]]; then
        line="FAILED=1 $* tag=$tag"
        echo "   FAILED: $*" >&2
    fi
    echo "at=$ts $line" >> "$out"
}

# Wait until the phone reports nominal (a hello run per minute, logged), at
# most COOL_MAX minutes.
cooldown() {
    local i
    for i in $(seq 1 "${COOL_MAX:-15}"); do
        launch "$R/dev-cooldown.txt" cooldown part=hello run=$i out=cooldown.txt
        tail -1 "$R/dev-cooldown.txt" | grep -q 'thermal_end=nominal' && return 0
        sleep 60
    done
}

if has build; then
    echo "== build (team $TEAM)"
    (cd app && xcodegen generate > /dev/null)
    xcodebuild -project app/KajoEntryLocality.xcodeproj -scheme KajoEntryLocality -configuration Release \
        -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM" build > "$SCRATCH/el-build.log" 2>&1 || { tail -30 "$SCRATCH/el-build.log"; exit 1; }
    xcrun devicectl device install app --device "$DEVICE" "$APP" > /dev/null
    launch "$R/dev-cooldown.txt" hello part=hello out=cooldown.txt
    tail -1 "$R/dev-cooldown.txt"
fi

p1() { # out tag mode size threads run
    launch "$1" "$2" part=1 mode="$3" size="$4" threads="$5" run="$6" out=part1.txt
}

if has part1; then
    O="$R/dev-part1.txt"
    echo "== part1: [$MODES] x [$SIZES] x 1, 2, 6 threads, $P1RUNS runs"
    cooldown
    for i in $(seq 1 "$DRIFT"); do p1 "$O" drift-start chase 256 1 "$i"; done
    for run in $(seq 1 "$P1RUNS"); do
        for s in $SIZES; do
            for m in $MODES; do
                p1 "$O" matrix "$m" "$s" 1 "$run"
                if (( s <= 512 )); then p1 "$O" matrix "$m" "$s" 2 "$run"; fi
                if (( s <= 192 )); then p1 "$O" matrix "$m" "$s" 6 "$run"; fi
            done
        done
        echo "   run $run/$P1RUNS done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
        cooldown
    done
    for i in $(seq 1 "$DRIFT"); do p1 "$O" drift-end chase 256 1 "$i"; done
fi

el() { # out tag variant kernel workers run
    launch "$1" "$2" part=3 variant="$3" kernel="$4" workers="$5" run="$6" out=part3.txt
}

if has hop; then
    O="$R/dev-hop.txt"
    echo "== hop: walkN, walkbuildN x A B C L x 20..23, $RUNS runs"
    cooldown
    for i in $(seq 1 "$DRIFT"); do el "$O" drift-start A walk22 1 "$i"; done
    for run in $(seq 1 "$RUNS"); do
        for n in 20 21 22 23; do
            for k in walk$n walkbuild$n; do
                for v in A B C L; do el "$O" matrix $v $k 1 $run; done
            done
        done
        echo "   run $run/$RUNS done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
        cooldown
    done
    for i in $(seq 1 "$DRIFT"); do el "$O" drift-end A walk22 1 "$i"; done
fi

if has orig; then
    O="$R/dev-orig.txt"
    echo "== orig: walk, walkbuild x A B C, 3 runs"
    for run in 1 2 3; do
        for k in walk walkbuild; do for v in A B C; do el "$O" orig $v $k 1 $run; done; done
    done
fi

if has compact; then
    O="$R/dev-compact.txt"
    echo "== compact: walkcompactN, walkcompactbuildN x A B L x 22, 23, $RUNS runs"
    cooldown
    for i in $(seq 1 "$DRIFT"); do el "$O" drift-start A walkcompact22 1 "$i"; done
    for run in $(seq 1 "$RUNS"); do
        for n in 22 23; do
            for k in walkcompact$n walkcompactbuild$n; do
                for v in A B L; do el "$O" matrix $v $k 1 $run; done
            done
        done
        echo "   run $run/$RUNS done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
        cooldown
    done
    for i in $(seq 1 "$DRIFT"); do el "$O" drift-end A walkcompact22 1 "$i"; done
fi

if has mark; then
    O="$R/dev-mark.txt"
    echo "== mark: walkmarkN x A B L x 22, 23, $RUNS runs"
    cooldown
    for i in $(seq 1 "$DRIFT"); do el "$O" drift-start A walkmark22 1 "$i"; done
    for run in $(seq 1 "$RUNS"); do
        for n in 22 23; do for v in A B L; do el "$O" matrix $v walkmark$n 1 $run; done; done
    done
    for i in $(seq 1 "$DRIFT"); do el "$O" drift-end A walkmark22 1 "$i"; done
fi

if has sends; then
    O="$R/dev-sends.txt"
    echo "== sends, ivars x A B L x 1, 6 workers, $RUNS runs"
    cooldown
    for i in $(seq 1 "$DRIFT"); do el "$O" drift-start A sends 1 "$i"; done
    for run in $(seq 1 "$RUNS"); do
        for k in sends ivars; do for w in 1 6; do for v in A B L; do el "$O" matrix $v $k $w $run; done; done; done
        echo "   run $run/$RUNS done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
    done
    for i in $(seq 1 "$DRIFT"); do el "$O" drift-end A sends 1 "$i"; done
fi

if has qos; then
    O="$R/dev-qos.txt"
    echo "== qos: walk22, walkbuild22 x A B x user-initiated, inherit; 3 runs"
    cooldown
    for run in 1 2 3; do
        for k in walk22 walkbuild22; do
            for v in A B; do
                el "$O" qos-ui $v $k 1 $run
                launch "$O" qos-inherit part=3 variant=$v kernel=$k workers=1 run=$run out=part3.txt KAJO_WORKER_QOS=inherit
            done
        done
    done
fi

if has work; then
    O="$R/dev-work.txt"
    echo "== work: chase dsep dlocal x [$WSIZES] x work 0, $WORK; 3 runs"
    cooldown
    for run in 1 2 3; do
        for sz in $WSIZES; do
            for m in chase dsep dlocal; do
                for w in 0 "$WORK"; do
                    launch "$O" work part=1 mode=$m size=$sz threads=1 work=$w run=$run out=work.txt
                done
            done
        done
        echo "   run $run/3 done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
    done
fi

if has membw; then
    O="$R/dev-membw.txt"
    echo "== membw: VM walks and chases, alone and with a $STREAM MB streaming companion; 3 runs"
    cooldown
    for run in 1 2 3; do
        for n in 21 22; do
            for k in walk$n walkbuild$n; do
                for v in A B L; do
                    for st in 0 "$STREAM"; do
                        launch "$O" membw part=3 variant=$v kernel=$k workers=1 run=$run stream=$st out=membw.txt
                    done
                done
            done
        done
        for sz in 64 256; do
            for m in chase dsep dlocal; do
                for st in 0 "$STREAM"; do
                    launch "$O" membw part=1 mode=$m size=$sz threads=1 run=$run stream=$st out=membw.txt
                done
            done
        done
        echo "   run $run/3 done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
    done
fi

if has membw2; then
    O="$R/dev-membw2.txt"
    echo "== membw2: walk22 x A B L, chase dsep 256 MB x companion off, [$RATES] MB/s; 3 runs"
    cooldown
    for run in 1 2 3; do
        for k in walk22 walkbuild22; do
            for v in A B L; do
                launch "$O" membw2 part=3 variant=$v kernel=$k workers=1 run=$run out=membw.txt
                for r in $RATES; do
                    launch "$O" membw2 part=3 variant=$v kernel=$k workers=1 run=$run stream=$STREAM rate=$r out=membw.txt
                done
            done
        done
        for m in chase dsep; do
            launch "$O" membw2 part=1 mode=$m size=256 threads=1 run=$run out=membw.txt
            for r in $RATES; do
                launch "$O" membw2 part=1 mode=$m size=256 threads=1 run=$run stream=$STREAM rate=$r out=membw.txt
            done
        done
        echo "   run $run/3 done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
    done
fi

if has lcg; then
    O="$R/dev-lcg.txt"
    echo "== lcg: chase dsep dlocal x 64, 256 MB x random, lcg order; 3 runs"
    for run in 1 2 3; do
        for sz in 64 256; do
            for m in chase dsep dlocal; do
                for o in random lcg; do
                    launch "$O" lcg part=1 mode=$m size=$sz threads=1 order=$o run=$run out=lcg.txt
                done
            done
        done
    done
fi

if has pull; then
    echo "== pull Documents"
    for f in part1 part3 work membw lcg cooldown; do
        xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE" --source "Documents/$f.txt" --destination "$R/device-$f.txt" > /dev/null 2>&1 || true
    done
fi

if has report; then
    python3 "$HERE/report.py" "$R" > "$HERE/bench-output.txt"
    cat "$HERE/bench-output.txt"
fi
