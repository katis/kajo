#!/usr/bin/env bash
# The runtime comparison (DESIGN.md): the five programs of programs/ on every
# runtime present, five interleaved rounds per kernel (round-robin over the
# runtimes within each round, so drift lands on everyone equally), every run
# bounded by gtimeout, the thermal state read at each run's start, the first
# kernel repeated at the end, one key=value line per run in bench-raw.txt.
#
# Installs nothing. A runtime that is not present is skipped and named in the
# header's `# missing:` line. Builds what the runs need first (the C
# binaries, the Java classes, Kajo's aligned release build and its images,
# one Pharo image per kernel with the program loaded), outside every timed
# run, into work/ (gitignored).
#
# Usage: experiments/runtime-comparison/bench.sh
#        ROUNDS=1 KERNELS="fib arith" RUNTIMES="kajo c" bench.sh   (a probe)
#        OUT=path bench.sh                                          (another raw file)
#
# Every run's `ms` is the wall time of the whole process (gdate around
# gtimeout), start-up included for every runtime alike; Kajo's own kernel
# time is kept beside it as `kernel_ms`. A run is `ok=yes` only when it
# exited 0 within the bound and printed the checksum in
# programs/<kernel>/checksums for its worker count; otherwise it is a
# refusal (`ok=no reason=timeout|exit|checksum`) and carries no number the
# report uses.
set -uo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
ROOT=$(cd ../.. && pwd)
ROUNDS=${ROUNDS:-5}
KERNELS=${KERNELS:-"fib dispatch binarytrees collections arith"}
OUT=${OUT:-"$HERE/bench-raw.txt"}
TIMEOUT=${TIMEOUT:-120}
WORK="$HERE/work"
PROGRAMS="$HERE/programs"
mkdir -p "$WORK"

# --- runtimes: label, kernels it runs, the binary that must exist ---------
NODE_BIN=${NODE_BIN:-"$HOME/Library/Application Support/fnm/node-versions/v24.5.0/installation/bin/node"}
[[ -x $NODE_BIN ]] || NODE_BIN=$(command -v node || true)
LUA_BIN=${LUA_BIN:-/opt/homebrew/bin/lua}
LUAJIT_BIN=${LUAJIT_BIN:-/opt/homebrew/bin/luajit}
RUBY_BIN=${RUBY_BIN:-/opt/homebrew/opt/ruby/bin/ruby}
PYTHON_BIN=${PYTHON_BIN:-/opt/homebrew/bin/python3}
JAVA_HOME_=${JAVA_HOME_:-/opt/homebrew/opt/openjdk}
JAVA_BIN="$JAVA_HOME_/bin/java"
JAVAC_BIN="$JAVA_HOME_/bin/javac"
CC_BIN=$(xcrun --find clang 2>/dev/null || true)
PHARO_DIR="$HERE/pharo"
PHARO_VM="$PHARO_DIR/pharo-vm/Pharo.app/Contents/MacOS/Pharo"
KAJO_SCRATCH="$ROOT/.build/perf"
KAJO_BIN="$KAJO_SCRATCH/release/kajo"
KAJO_PRELUDE="$ROOT/Tests/KajoVMTests/Fixtures/kernels/prelude.kasm"

FOUR="fib dispatch binarytrees arith"
ALL="fib dispatch binarytrees collections arith"
# label|kernels|workers kernels (the 8-worker row)
RUNTIME_TABLE="
kajo|$FOUR|fib dispatch binarytrees
kajo-st|$ALL|fib dispatch binarytrees
pharo|$ALL|
c|$FOUR|
luajit|$FOUR|
luajit-joff|$FOUR|
lua|$FOUR|
node|$FOUR|
node-jitless|$FOUR|
java|$FOUR|
java-int|$FOUR|
java-zgc|binarytrees|
ruby|$FOUR|
ruby-yjit|$FOUR|
python|$FOUR|
"
RUNTIMES=${RUNTIMES:-$(echo "$RUNTIME_TABLE" | awk -F'|' 'NF { print $1 }' | tr '\n' ' ')}

field() { # label column
    echo "$RUNTIME_TABLE" | awk -F'|' -v l="$1" -v c="$2" '$1 == l { print $c }'
}
has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

present() { # label -> 0 if its binary runs on this Mac
    case $1 in
        kajo|kajo-st) [[ -n $(command -v swift) ]] ;;
        pharo) [[ -x $PHARO_VM && -f $PHARO_DIR/Pharo.image ]] ;;
        c) [[ -n $CC_BIN ]] ;;
        luajit|luajit-joff) [[ -x $LUAJIT_BIN ]] ;;
        lua) [[ -x $LUA_BIN ]] ;;
        node|node-jitless) [[ -n $NODE_BIN && -x $NODE_BIN ]] ;;
        java|java-int|java-zgc) [[ -x $JAVA_BIN && -x $JAVAC_BIN ]] ;;
        ruby) [[ -x $RUBY_BIN ]] ;;
        ruby-yjit) [[ -x $RUBY_BIN ]] && "$RUBY_BIN" --yjit -e 'exit(RubyVM::YJIT.enabled? ? 0 : 1)' 2>/dev/null ;;
        python) [[ -x $PYTHON_BIN ]] ;;
        *) return 1 ;;
    esac
}

version_of() { # label -> one line, spaces kept, no '=' in it
    local v
    case $1 in
        kajo|kajo-st) v="$(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet HEAD -- Sources Package.swift kernel 2>/dev/null || echo -dirty) release -enable-testing aligned, $(swift --version 2>/dev/null | head -1 | sed 's/^.*Swift version /Swift /; s/ (.*//')" ;;
        pharo) v=$(gtimeout 60 "$PHARO_VM" --headless "$PHARO_DIR/Pharo.image" eval "Smalltalk version, ' / ', (Smalltalk vm version lines last)" 2>/dev/null | tr -d "'" | head -1) ;;
        c) v="$(xcrun clang --version | head -1), -O2" ;;
        luajit|luajit-joff) v=$("$LUAJIT_BIN" -v | awk '{ print $1, $2 }') ;;
        lua) v=$("$LUA_BIN" -v | awk '{ print $1, $2 }') ;;
        node|node-jitless) v="Node $("$NODE_BIN" --version) (V8 $("$NODE_BIN" -p process.versions.v8))" ;;
        java|java-int|java-zgc) v=$("$JAVA_BIN" -version 2>&1 | sed -n 2p) ;;
        ruby|ruby-yjit) v=$("$RUBY_BIN" --version | awk '{ print $1, $2 }') ;;
        python) v=$("$PYTHON_BIN" --version 2>&1) ;;
    esac
    echo "$v" | tr '=\n' ':' | sed 's/:$//'
}

thermal() { "$WORK/thermal" 2>/dev/null || echo unknown; }

# --- builds, outside every timed run ---------------------------------------
build_all() {
    echo "== builds"
    xcrun swiftc -O -o "$WORK/thermal" "$HERE/thermal.swift" || return 1
    if has_word "$ACTIVE" kajo || has_word "$ACTIVE" kajo-st; then
        (cd "$ROOT" && swift build -c release --product kajo --scratch-path "$KAJO_SCRATCH" \
            -Xswiftc -enable-testing \
            -Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5 \
            -Xswiftc -Xllvm -Xswiftc -align-loops=32 >/dev/null) || { echo "kajo build failed"; return 1; }
    fi
    for k in $KERNELS; do
        local p="$PROGRAMS/$k"
        if has_word "$ACTIVE" kajo-st && has_word "$(field kajo-st 2)" "$k"; then
            "$KAJO_BIN" build-image -o "$WORK/kajo-$k.img" "$ROOT/kernel" "$p/smalltalk" >/dev/null || { echo "kajo image $k failed"; return 1; }
        fi
        if has_word "$ACTIVE" c && [[ -f $p/c.c ]]; then
            xcrun clang -O2 -o "$WORK/c-$k" "$p/c.c" || return 1
            # A new binary's first launch waits for the system's code check
            # (230 against 82 ms on fib); launch it once untimed.
            gtimeout "$TIMEOUT" "$WORK/c-$k" >/dev/null || return 1
        fi
        if [[ -f $p/java.java ]] && { has_word "$ACTIVE" java || has_word "$ACTIVE" java-int || has_word "$ACTIVE" java-zgc; }; then
            rm -rf "$WORK/java-$k"; mkdir -p "$WORK/java-$k"
            "$JAVAC_BIN" -d "$WORK/java-$k" "$p/java.java" || return 1
        fi
        if has_word "$ACTIVE" pharo && has_word "$(field pharo 2)" "$k"; then
            cp "$PHARO_DIR/Pharo.image" "$WORK/pharo-$k.image"
            cp "$PHARO_DIR/Pharo.changes" "$WORK/pharo-$k.changes"
            for s in "$PHARO_DIR"/*.sources; do ln -sf "$s" "$WORK/"; done
            gtimeout 300 "$PHARO_VM" --headless "$WORK/pharo-$k.image" st "$HERE/pharo-load.st" "$p/smalltalk" >/dev/null 2>&1 \
                || { echo "pharo image $k failed"; return 1; }
        fi
    done
}

# --- one run's command line into CMD ---------------------------------------
PHARO_EVAL='| a b r | a := (7 to: 10) collect: [:i | Smalltalk vm parameterAt: i]. r := nil run: 0 of: 1. b := (7 to: 10) collect: [:i | Smalltalk vm parameterAt: i]. Stdio stderr nextPutAll: '\''pharo_gc full='\'', ((b at: 1) - (a at: 1)) printString, '\'' full_ms='\'', ((b at: 2) - (a at: 2)) printString, '\'' scavenges='\'', ((b at: 3) - (a at: 3)) printString, '\'' scavenge_ms='\'', ((b at: 4) - (a at: 4)) printString; lf; flush. r'
command_for() { # label kernel workers
    local p="$PROGRAMS/$2"
    case $1 in
        kajo) CMD=("$KAJO_BIN" run "$KAJO_PRELUDE" "$p/kajo.kasm" --workers "$3" --slice-ms 0) ;;
        kajo-st) CMD=("$KAJO_BIN" run "$WORK/kajo-$2.img" --workers "$3" --slice-ms 0) ;;
        pharo) CMD=("$PHARO_VM" --headless "$WORK/pharo-$2.image" eval "$PHARO_EVAL") ;;
        c) CMD=("$WORK/c-$2") ;;
        luajit) CMD=("$LUAJIT_BIN" "$p/lua.lua") ;;
        luajit-joff) CMD=("$LUAJIT_BIN" -joff "$p/lua.lua") ;;
        lua) CMD=("$LUA_BIN" "$p/lua.lua") ;;
        node) CMD=("$NODE_BIN" "$p/node.js") ;;
        node-jitless) CMD=("$NODE_BIN" --jitless "$p/node.js") ;;
        java) CMD=("$JAVA_BIN" -XX:+UseG1GC -Xlog:gc:stderr -cp "$WORK/java-$2" Main) ;;
        java-int) CMD=("$JAVA_BIN" -Xint -XX:+UseG1GC -Xlog:gc:stderr -cp "$WORK/java-$2" Main) ;;
        java-zgc) CMD=("$JAVA_BIN" -XX:+UseZGC -XX:+ZGenerational -Xlog:gc,gc+phases:stderr -cp "$WORK/java-$2" Main) ;;
        ruby) CMD=("$RUBY_BIN" "$p/ruby.rb") ;;
        ruby-yjit) CMD=("$RUBY_BIN" --yjit "$p/ruby.rb") ;;
        python) CMD=("$PYTHON_BIN" "$p/python.py") ;;
    esac
}

expected() { # kernel workers -> checksum
    awk -v w="workers=$2" '$1 == w { sub(/^checksum=/, "", $2); print $2 }' "$PROGRAMS/$1/checksums"
}

kv() { # key line -> value of key= in a key=value line
    echo "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1
}

pause_stats() { # file of JVM log -> "pauses=N pause_p50= pause_p99= pause_max="
    grep -E '\bPause\b' "$1" | sed -E 's/.* ([0-9]+\.[0-9]+)ms$/\1/' | grep -E '^[0-9.]+$' | sort -g |
        awk '{ v[NR] = $1 } END {
            if (NR == 0) { print "pauses=0 pause_p50=- pause_p99=- pause_max=-"; exit }
            i50 = int((NR * 50 + 99) / 100); i99 = int((NR * 99 + 99) / 100)
            printf "pauses=%d pause_p50=%.3f pause_p99=%.3f pause_max=%.3f\n", NR, v[i50], v[i99], v[NR] }'
}

run_one() { # label kernel workers round
    local label=$1 k=$2 n=$3 round=$4
    command_for "$label" "$k" "$n"
    local th t0 t1 status out err ms checksum ok reason extra want
    th=$(thermal)
    out="$WORK/last.out"; err="$WORK/last.err"
    t0=$(gdate +%s%N)
    gtimeout "$TIMEOUT" "${CMD[@]}" >"$out" 2>"$err"
    status=$?
    t1=$(gdate +%s%N)
    ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", (b - a) / 1e6 }')
    extra=""
    case $label in
        kajo|kajo-st)
            local line; line=$(grep '^checksum=' "$out" | tail -1)
            checksum=$(kv checksum "$line")
            extra="kernel_ms=$(kv ms "$line") stops=$(kv stops "$line") pause_p50=$(kv pauseP50ms "$line") pause_p99=$(kv pauseP99ms "$line") pause_max=$(kv pauseMaxMs "$line") young=$(( $(kv ycLocal "$line" | grep . || echo 0) + $(kv ycOffloaded "$line" | grep . || echo 0) )) young_p50=$(kv ycLocalP50ms "$line") young_p99=$(kv ycLocalP99ms "$line") cycles=$(kv cycles "$line") fallbacks=$(kv fallbacks "$line")" ;;
        pharo)
            checksum=$(tail -1 "$out" | tr -d "' \r")
            local g; g=$(grep '^pharo_gc' "$err" | tail -1)
            extra="full=$(kv full "$g") full_ms=$(kv full_ms "$g") scavenges=$(kv scavenges "$g") scavenge_ms=$(kv scavenge_ms "$g")" ;;
        java|java-int|java-zgc)
            checksum=$(tail -1 "$out" | tr -d ' \r')
            extra=$(pause_stats "$err") ;;
        *)
            checksum=$(tail -1 "$out" | tr -d ' \r') ;;
    esac
    [[ -n $checksum ]] || checksum=-
    want=$(expected "$k" "$n")
    if [[ $status -eq 124 ]]; then ok=no; reason=timeout
    elif [[ $status -ne 0 ]]; then ok=no; reason=exit$status
    elif [[ $checksum != "$want" ]]; then ok=no; reason=checksum
    else ok=yes; reason=-
    fi
    echo "runtime=$label version=$(echo "${VERSIONS[$(index_of "$label")]}" | tr ' ' '_') kernel=$k workers=$n round=$round ms=$ms checksum=$checksum want=$want thermal=$th ok=$ok reason=$reason $extra" >>"$OUT"
    printf '  %-12s %-11s w=%s r=%-6s %10s ms  %-9s %s\n' "$label" "$k" "$n" "$round" "$ms" "$th" "$ok${reason/#-/}"
}

index_of() { local i=0; for r in $ACTIVE; do [[ $r == "$1" ]] && { echo $i; return; }; i=$((i + 1)); done; echo 0; }

# --- main -----------------------------------------------------------------
ACTIVE=""; MISSING=""
for r in $RUNTIMES; do
    if present "$r"; then ACTIVE="$ACTIVE $r"; else MISSING="$MISSING $r"; fi
done
ACTIVE=${ACTIVE# }; MISSING=${MISSING# }
build_all || { echo "build failed"; exit 2; }

declare -a VERSIONS=()
for r in $ACTIVE; do VERSIONS+=("$(version_of "$r")"); done

{
    echo "# runtime-comparison raw runs (experiments/runtime-comparison/bench.sh)"
    echo "# date: $(date '+%Y-%m-%d %H:%M %Z')"
    echo "# commit: $(git -C "$ROOT" rev-parse --short HEAD)"
    echo "# machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.perflevel0.physicalcpu) P-cores + $(sysctl -n hw.perflevel1.physicalcpu) E-cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, $(sysctl -n hw.model)"
    echo "# macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "# rounds: $ROUNDS"
    echo "# timeout: ${TIMEOUT} s"
    echo "# missing: ${MISSING:--}"
    i=0
    for r in $ACTIVE; do echo "# version $r: ${VERSIONS[$i]}"; i=$((i + 1)); done
} >"$OUT"
cat "$OUT"

FIRST=""
for k in $KERNELS; do
    [[ -z $FIRST ]] && FIRST=$k
    echo "== $k"
    for round in $(seq 1 "$ROUNDS"); do
        for r in $ACTIVE; do
            has_word "$(field "$r" 2)" "$k" || continue
            run_one "$r" "$k" 1 "$round"
            has_word "$(field "$r" 3)" "$k" && run_one "$r" "$k" 8 "$round"
        done
    done
done
if [[ -n $FIRST ]]; then
    echo "== $FIRST again (drift check)"
    for r in $ACTIVE; do
        has_word "$(field "$r" 2)" "$FIRST" || continue
        run_one "$r" "$FIRST" 1 repeat
        has_word "$(field "$r" 3)" "$FIRST" && run_one "$r" "$FIRST" 8 repeat
    done
fi
echo "# end: $(date '+%Y-%m-%d %H:%M %Z')" >>"$OUT"
echo "== wrote $OUT"
