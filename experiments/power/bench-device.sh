#!/usr/bin/env bash
# Build, sign, install and run the power matrices on the phone
# (device-measurement's and entry-locality's pattern): one configuration per
# launch over devicectl, each result line streamed and appended to
# results/dev-*.txt with the launch time `at=`; the app also appends it to
# Documents/, pulled at the end as results/device-*.txt. Every matrix is
# preceded by a cool-down to nominal and starts and ends with DRIFT runs of
# its first configuration. Configurations are interleaved run by run.
#
#   hello    the energy readout check (part=hello), 3 launches
#   p1       walk22x4 and walkbuild22 on B, 1 worker, beside each companion
#            in [COMPS]; walk23x4/walkbuild23 with 2 workers (each its own
#            2^22 graph) without a companion; P1RUNS runs
#   p1chase  chase 256 MB, 1 thread, alone and with a spinning companion
#   p2       the rate matrix: [RATES] MB/s x stw conc-high conc-utility
#            conc-mixed, SECONDS each, P2RUNS runs
#   p2quiet  1 MB/s for 60 s, stw and conc-utility, P2RUNS runs
#   p3       idle: novm parked link tick tickalloc (2 MB/s, utility and
#            user-initiated), 60 s each, P3RUNS runs
#   p1x      added after p1: walk22x4 only, alone / t10000 / wfe / spin,
#            P1XRUNS runs, to count slow-regime launches per configuration
#            (p1's builds are reused)
#   p2x      added after p2: 100 and 150 MB/s x the four configurations,
#            P2RUNS runs, to place where conc-utility starts missing frames
#   p3x      added after p3: parked and tick with KAJO_GC=stw (no marker
#            thread), P3RUNS runs, to name the source of idle wakeups
#   p3fix    added after concurrent-young's SPEC amendment 18 (the marker
#            waits untimed unless blocks are pending): parked and tick at
#            conc-utility and conc-high, P3RUNS runs
#   pull     copy Documents/*.txt from the phone into results/device-*.txt
#
# Usage: SCRATCH=<dir> ./bench-device.sh                 (everything)
#        SCRATCH=<dir> PARTS="build hello" ./bench-device.sh
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
DEVICE=${DEVICE:-00008150-001271502182401C}
TEAM=${TEAM:-BDN6M642M2}
BUNDLE=dev.katajamaki.kajo.power
DRIFT=${DRIFT:-1}
P1RUNS=${P1RUNS:-5}
P2RUNS=${P2RUNS:-3}
P3RUNS=${P3RUNS:-3}
SECONDS_P2=${SECONDS_P2:-30}
COMPS=${COMPS:-"none spin t10000 t1000 t100 spinut wfe"}
RATES=${RATES:-"2 10 50 200"}
CFGS=${CFGS:-"stw conc-high conc-utility conc-mixed"}
PARTS=${PARTS:-"build hello p1 p1chase p2 p2quiet p3 pull"}
SCRATCH=${SCRATCH:?set SCRATCH to a scratch directory}
DD="$SCRATCH/DerivedData-power"
APP="$DD/Build/Products/Release-iphoneos/KajoPower.app"
R="$HERE/results"
mkdir -p "$R"
has() { [[ " $PARTS " == *" $1 "* ]]; }

# launch <outfile> <tag> args...: one run, its result line appended to <outfile>.
launch() {
    local out=$1 tag=$2; shift 2
    local ts line
    ts=$(date +%s)
    line=$(gtimeout 400 xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing \
        "$BUNDLE" "tag=$tag" "$@" 2>&1 | grep -E '^part=' | tail -1 || true)
    if [[ -z "$line" ]]; then
        line="FAILED=1 $* tag=$tag"
        echo "   FAILED: $*" >&2
    fi
    echo "at=$ts $line" >> "$out"
}

# Wait until the phone reports nominal (a hello run per minute, logged), at
# most COOL_MAX minutes. Refuse to go on at serious.
cooldown() {
    local i
    for i in $(seq 1 "${COOL_MAX:-20}"); do
        launch "$R/dev-cooldown.txt" cooldown part=hello run=$i out=cooldown.txt
        tail -1 "$R/dev-cooldown.txt" | grep -q 'thermal_end=nominal' && return 0
        sleep 60
    done
    if tail -1 "$R/dev-cooldown.txt" | grep -q 'thermal_end=serious\|thermal_end=critical'; then
        echo "phone still serious after cool-down; stopping" >&2; exit 1
    fi
}

if has build; then
    echo "== build (team $TEAM)"
    (cd app && xcodegen generate > /dev/null)
    xcodebuild -project app/KajoPower.xcodeproj -scheme KajoPower -configuration Release \
        -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM" build > "$SCRATCH/power-build.log" 2>&1 || { grep -E "error:" "$SCRATCH/power-build.log" | cut -c1-300 | head -20; exit 1; }
    xcrun devicectl device install app --device "$DEVICE" "$APP" > /dev/null
fi

if has hello; then
    echo "== hello: the energy readout"
    for i in 1 2 3; do launch "$R/dev-hello.txt" hello part=hello run=$i out=hello.txt; done
    tail -3 "$R/dev-hello.txt" | grep -o 'idle_energy_mj=[0-9.]* busy_energy_mj=[0-9.]*'
fi

walk() { # out tag kernel workers comp run
    launch "$1" "$2" part=1 kernel="$3" workers="$4" comp="$5" run="$6" out=p1.txt
}

if has p1; then
    O="$R/dev-p1.txt"
    echo "== p1: walk22x4, walkbuild22 x [$COMPS]; 2 workers; $P1RUNS runs"
    cooldown
    for i in $(seq 1 "$DRIFT"); do walk "$O" drift-start walk22x4 1 none "$i"; done
    for run in $(seq 1 "$P1RUNS"); do
        for c in $COMPS; do
            walk "$O" matrix walk22x4 1 "$c" "$run"
            walk "$O" matrix walkbuild22 1 "$c" "$run"
        done
        walk "$O" matrix walk23x4 2 none "$run"
        walk "$O" matrix walkbuild23 2 none "$run"
        echo "   run $run/$P1RUNS done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
        if (( run % 2 == 0 )); then cooldown; fi
    done
    for i in $(seq 1 "$DRIFT"); do walk "$O" drift-end walk22x4 1 none "$i"; done
fi

if has p1chase; then
    O="$R/dev-p1chase.txt"
    echo "== p1chase: chase 256 MB, alone and with a spinning companion"
    for run in $(seq 1 "$P1RUNS"); do
        for c in none spin wfe; do launch "$O" matrix part=1c size=256 hops=33554432 comp="$c" run="$run" out=p1chase.txt; done
    done
fi

cfgargs() { # cfg -> collector env args
    case $1 in
        stw) echo "KAJO_GC=stw KAJO_YOUNG=stw KAJO_AGE=2" ;;
        conc-high) echo "KAJO_GC=cm KAJO_YOUNG=offload KAJO_AGE=2 KAJO_YC_QOS=initiated KAJO_CM_QOS=high" ;;
        conc-utility) echo "KAJO_GC=cm KAJO_YOUNG=offload KAJO_AGE=2 KAJO_YC_QOS=utility KAJO_CM_QOS=utility" ;;
        conc-mixed) echo "KAJO_GC=cm KAJO_YOUNG=offload KAJO_AGE=2 KAJO_YC_QOS=initiated KAJO_CM_QOS=utility" ;;
    esac
}

p2() { # out tag cfg rate seconds run
    # shellcheck disable=SC2046
    launch "$1" "$2" part=2 cfg="$3" rate="$4" seconds="$5" run="$6" out=p2.txt $(cfgargs "$3")
}

if has p2; then
    O="$R/dev-p2.txt"
    echo "== p2: [$RATES] MB/s x [$CFGS], ${SECONDS_P2} s, $P2RUNS runs"
    cooldown
    first_rate=${RATES%% *}; first_cfg=${CFGS%% *}
    for i in $(seq 1 "$DRIFT"); do p2 "$O" drift-start "$first_cfg" "$first_rate" "$SECONDS_P2" "$i"; done
    for run in $(seq 1 "$P2RUNS"); do
        for r in $RATES; do
            for c in $CFGS; do p2 "$O" matrix "$c" "$r" "$SECONDS_P2" "$run"; done
        done
        echo "   run $run/$P2RUNS done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
        cooldown
    done
    for i in $(seq 1 "$DRIFT"); do p2 "$O" drift-end "$first_cfg" "$first_rate" "$SECONDS_P2" "$i"; done
fi

if has p2quiet; then
    O="$R/dev-p2quiet.txt"
    echo "== p2quiet: 1 MB/s, 60 s, stw and conc-utility"
    cooldown
    for run in $(seq 1 "$P2RUNS"); do
        for c in stw conc-utility; do p2 "$O" matrix "$c" 1 60 "$run"; done
    done
    p2 "$O" drift-end stw 1 60 1
fi

p3() { # out tag mode cfg run
    local m=$3 c=$4 run=$5
    # shellcheck disable=SC2046
    launch "$1" "$2" part=3 mode="$m" cfg="$c" rate=2 seconds=60 run="$run" out=p3.txt $(cfgargs "$c")
}

if has p3; then
    O="$R/dev-p3.txt"
    echo "== p3: idle, 60 s each, $P3RUNS runs"
    cooldown
    for run in $(seq 1 "$P3RUNS"); do
        p3 "$O" matrix novm conc-utility "$run"
        p3 "$O" matrix parked conc-utility "$run"
        p3 "$O" matrix link conc-utility "$run"
        p3 "$O" matrix tick conc-utility "$run"
        p3 "$O" matrix tickalloc conc-utility "$run"
        p3 "$O" matrix tickalloc conc-high "$run"
        echo "   run $run/$P3RUNS done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
    done
    p3 "$O" drift-end novm conc-utility 1
fi

if has p1x; then
    O="$R/dev-p1x.txt"
    echo "== p1x: walk22x4 x none t10000 wfe spin, ${P1XRUNS:-8} runs"
    cooldown
    for run in $(seq 1 "${P1XRUNS:-8}"); do
        for c in none t10000 wfe spin; do walk "$O" matrix walk22x4 1 "$c" "$run"; done
        echo "   run $run done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
        if (( run % 4 == 0 )); then cooldown; fi
    done
    walk "$O" drift-end walk22x4 1 none 1
fi

if has p2x; then
    O="$R/dev-p2x.txt"
    echo "== p2x: 100 150 MB/s x [$CFGS], ${SECONDS_P2} s, $P2RUNS runs"
    cooldown
    for run in $(seq 1 "$P2RUNS"); do
        for r in 100 150; do
            for c in $CFGS; do p2 "$O" matrix "$c" "$r" "$SECONDS_P2" "$run"; done
        done
        echo "   run $run/$P2RUNS done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
        cooldown
    done
fi

if has p3x; then
    O="$R/dev-p3x.txt"
    echo "== p3x: parked, tick with no marker (stw), $P3RUNS runs"
    for run in $(seq 1 "$P3RUNS"); do
        p3 "$O" matrix parked stw "$run"
        p3 "$O" matrix tick stw "$run"
    done
fi

if has p3fix; then
    O="$R/dev-p3fix.txt"
    echo "== p3fix: parked, tick x conc-utility conc-high after the untimed marker wait, $P3RUNS runs"
    cooldown
    for run in $(seq 1 "$P3RUNS"); do
        for c in conc-utility conc-high; do
            p3 "$O" matrix parked "$c" "$run"
            p3 "$O" matrix tick "$c" "$run"
        done
        echo "   run $run/$P3RUNS done ($(tail -1 "$O" | grep -o 'thermal_end=[a-z]*'))"
    done
fi

if has pull; then
    echo "== pull Documents"
    for f in hello p1 p1chase p2 p3 cooldown unplugged smoke; do
        xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE" --source "Documents/$f.txt" --destination "$R/device-$f.txt" > /dev/null 2>&1 || true
    done
fi
