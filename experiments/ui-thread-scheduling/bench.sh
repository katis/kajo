#!/usr/bin/env bash
# Build everything, run the kernel matrix and the AppKit scenarios, print tables.
#
# Kernels: fib sends arith alloc x 1, 8 workers x 4 VMs x 2 builds, RUNS (5)
# interleaved runs, medians. VMs:
#   B      variant B, ../object-representation (orep-bench B), built into
#          this package's scratch directory; that tree is not modified
#   P      this VM: Process stacks, scheduler, budget countdown, 5 ms slices
#   P0     P with KAJO_SLICE_MS=0 (countdown runs, never preempts)
#   Pnb    P compiled with -DNO_BUDGET (no countdown in the poll)
# Builds: O (-c release) and align32 (O + -align-all-nofallthru-blocks=5).
# Poll-divisor sweep: arith, 1 worker, P, N = 64 256 1024 4096.
# Scenarios: S0..S7 and S1n, SRUNS (3) runs each, 10 s measured; the median
# run (by missed frames, then max gap) is reported.
#
# Usage: ./bench.sh            (everything)
#        PARTS="kernels" RUNS=1 ./bench.sh
#        PARTS="scenarios" SCENARIOS="S0 S2" ./bench.sh
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
RUNS=${RUNS:-5}
SRUNS=${SRUNS:-3}
SECONDS_PER=${SECONDS_PER:-10}
PARTS=${PARTS:-"build kernels sweep scenarios"}
KERNELS=${KERNELS:-"fib sends arith alloc"}
SCENARIOS=${SCENARIOS:-"S0 S1 S1n S2 S3 S4 S5 S6 S7"}
KRAW=${KRAW:-"$HERE/bench-raw-kernels.txt"}
SRAW=${SRAW:-"$HERE/bench-raw-scenarios.txt"}
OREP="$HERE/../object-representation/swift"
ALIGN=(-Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5)
S="$HERE/swift"

has() { [[ " $PARTS " == *" $1 "* ]]; }

if has build; then
    echo "== builds"
    swift build -c release --package-path "$S" --product uts-bench
    swift build -c release --package-path "$S" --product kajo-ui
    swift build -c release --package-path "$S" --product uts-bench --scratch-path "$S/.build/nobudget" -Xswiftc -DNO_BUDGET
    swift build -c release --package-path "$S" --product uts-bench --scratch-path "$S/.build/align" "${ALIGN[@]}"
    swift build -c release --package-path "$S" --product uts-bench --scratch-path "$S/.build/nobudget-align" -Xswiftc -DNO_BUDGET "${ALIGN[@]}"
    swift build -c release --package-path "$OREP" --product orep-bench --scratch-path "$S/.build/varb"
    swift build -c release --package-path "$OREP" --product orep-bench --scratch-path "$S/.build/varb-align" "${ALIGN[@]}"
fi

# vm|build|command prefix (kernel and workers are appended)
CONFIGS=(
    "B|O|$S/.build/varb/release/orep-bench B"
    "P|O|$S/.build/release/uts-bench kernel"
    "P0|O|env KAJO_SLICE_MS=0 $S/.build/release/uts-bench kernel"
    "Pnb|O|$S/.build/nobudget/release/uts-bench kernel"
    "B|align32|$S/.build/varb-align/release/orep-bench B"
    "P|align32|$S/.build/align/release/uts-bench kernel"
    "P0|align32|env KAJO_SLICE_MS=0 $S/.build/align/release/uts-bench kernel"
    "Pnb|align32|$S/.build/nobudget-align/release/uts-bench kernel"
)

header() {
    echo "# machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.perflevel0.physicalcpu) P-cores + $(sysctl -n hw.perflevel1.physicalcpu) E-cores, macOS $(sw_vers -productVersion), no pinning"
    echo "# $(swift --version 2>&1 | head -1)"
}

if has kernels; then
    echo "== kernels: [$KERNELS] x 1,8 workers x B P P0 Pnb x O align32, $RUNS runs"
    header > "$KRAW"
    for run in $(seq 1 "$RUNS"); do
        for k in $KERNELS; do
            for n in 1 8; do
                for c in "${CONFIGS[@]}"; do
                    IFS='|' read -r vmname build cmd <<< "$c"
                    echo "cfg=$vmname build=$build run=$run $($cmd "$k" "$n")" >> "$KRAW"
                done
            done
        done
        echo "   run $run/$RUNS done"
    done
fi

if has sweep; then
    echo "== poll divisor sweep (arith, 1 worker, P, O build), $RUNS runs"
    for run in $(seq 1 "$RUNS"); do
        for pn in 64 256 1024 4096; do
            echo "cfg=sweep build=O run=$run $(KAJO_POLL_N=$pn "$S/.build/release/uts-bench" kernel arith 1)" >> "$KRAW"
        done
        echo "cfg=sweepnb build=O run=$run $("$S/.build/nobudget/release/uts-bench" kernel arith 1)" >> "$KRAW"
    done
    echo "cfg=clock $("$S/.build/release/uts-bench" clock)" >> "$KRAW"
fi

if has scenarios; then
    echo "== scenarios: [$SCENARIOS], $SRUNS runs x ${SECONDS_PER} s (a window will appear)"
    header > "$SRAW"
    for run in $(seq 1 "$SRUNS"); do
        for sc in $SCENARIOS; do
            "$S/.build/release/kajo-ui" "$sc" --seconds "$SECONDS_PER" --run "$run" --out "$SRAW" \
                > /dev/null 2>> "$HERE/swift/.build/kajo-ui-stderr.txt" || echo "   $sc run $run FAILED"
            sleep 1
        done
        echo "   run $run/$SRUNS done"
    done
fi

python3 - "$KRAW" "$SRAW" <<'PY'
import sys, os, statistics as st, collections

def parse(path):
    rows = []
    if not os.path.exists(path): return rows
    for line in open(path):
        if line.startswith('#'):
            print(line.strip()); continue
        kv = {}
        for t in line.split():
            if '=' in t:
                k, v = t.split('=', 1); kv[k] = v
        rows.append(kv)
    return rows

k = parse(sys.argv[1])
grp = collections.defaultdict(list)
for r in k:
    if r.get('cfg') in ('B', 'P', 'P0', 'Pnb'):
        grp[(r['kernel'], int(r['workers']), r['build'], r['cfg'])].append(r)
def med(key, f='ms'):
    v = [float(r[f]) for r in grp.get(key, []) if f in r]
    return st.median(v) if v else None
if grp:
    print("\n## Kernels: median wall ms, ratio to variant B (same session)\n")
    print("| kernel | workers | build | B ms | Pnb ms | P0 ms | P ms | Pnb/B | P0/Pnb | P/P0 | P/B | checksum | equal |")
    print("|---|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|---|:-:|")
    for kern in ['fib', 'sends', 'arith', 'alloc']:
        for n in (1, 8):
            sums = {r['checksum'] for (kk, nn, b, c), rs in grp.items() if kk == kern and nn == n for r in rs}
            for b in ('O', 'align32'):
                m = {c: med((kern, n, b, c)) for c in ('B', 'Pnb', 'P0', 'P')}
                if m['B'] is None: continue
                f = lambda x: f"{x:.1f}" if x else "-"
                rr = lambda a, c: f"{m[a] / m[c]:.3f}" if m[a] and m[c] else "-"
                print(f"| {kern} | {n} | {b} | {f(m['B'])} | {f(m['Pnb'])} | {f(m['P0'])} | {f(m['P'])} | {rr('Pnb','B')} | {rr('P0','Pnb')} | {rr('P','P0')} | {rr('P','B')} | {sorted(sums)[0]} | {'yes' if len(sums) == 1 else 'NO'} |")
    print("\n## Kernel side counters (P, O build, medians)\n")
    print("| kernel | workers | slices | preemptions | sched locks | contended | sched wait ms | GCs |")
    print("|---|--:|--:|--:|--:|--:|--:|--:|")
    for kern in ['fib', 'sends', 'arith', 'alloc']:
        for n in (1, 8):
            key = (kern, n, 'O', 'P')
            if key not in grp: continue
            g = lambda f: med(key, f) or 0
            print(f"| {kern} | {n} | {g('slices'):.0f} | {g('preemptions'):.0f} | {g('schedLocks'):.0f} | {g('schedContended'):.0f} | {g('schedWait_ms'):.3f} | {g('gcCount'):.0f} |")

sw = collections.defaultdict(list)
for r in k:
    if r.get('cfg') == 'sweep': sw[int(r['pollN'])].append(float(r['ms']))
    if r.get('cfg') == 'sweepnb': sw[0].append(float(r['ms']))
    if r.get('cfg') == 'clock': print("\nclock:", " ".join(f"{a}={b}" for a, b in r.items() if a != 'cfg'))
if sw:
    base = st.median(sw[0]) if sw.get(0) else None
    print("\n## Poll divisor N (arith, 1 worker, 5 ms slices, O build; overhead vs NO_BUDGET)\n")
    print("| N | median ms | runs | overhead |")
    print("|--:|--:|--:|--:|")
    if base: print(f"| no countdown (NO_BUDGET) | {base:.1f} | {len(sw[0])} | - |")
    for n in sorted(x for x in sw if x):
        m = st.median(sw[n])
        print(f"| {n} | {m:.1f} | {len(sw[n])} | {((m / base - 1) * 100 if base else 0):+.2f}% |")

s = parse(sys.argv[2])
sg = collections.defaultdict(list)
for r in s: sg[r['scenario']].append(r)
def fl(r, f, d=0.0):
    try: return float(r.get(f, d))
    except ValueError: return d
def median_run(rs):
    rs = sorted(rs, key=lambda r: (fl(r, 'missed'), fl(r, 'gap_max_ms')))
    return rs[(len(rs) - 1) // 2]
order = ['S0', 'S1', 'S1n', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7']
if sg:
    print("\n## Scenarios: median run of", max(len(v) for v in sg.values()), "(by missed frames, then max gap)\n")
    print("| id | refresh Hz | frames | drops | missed | gap p50 ms | gap p99 ms | gap max ms | cb late p99 ms | ev lat p50/p99/max ms | ev post-lat p50/p99 ms | worst run-loop iter ms (VM, GC park) | stuck | per-run missed |")
    print("|---|--:|--:|--:|--:|--:|--:|--:|--:|---|---|---|--:|---|")
    for sc in order:
        if sc not in sg: continue
        r = median_run(sg[sc])
        ev = f"{r['ev_lat_p50_ms']} / {r['ev_lat_p99_ms']} / {r['ev_lat_max_ms']}" if 'ev_lat_p50_ms' in r else (
             f"{r['native_lat_p50_ms']} / {r['native_lat_p99_ms']} / {r['native_lat_max_ms']} (native)" if 'native_lat_p50_ms' in r else "-")
        evp = f"{r['ev_post_lat_p50_ms']} / {r['ev_post_lat_p99_ms']}" if 'ev_post_lat_p50_ms' in r else "-"
        per = ", ".join(str(int(fl(x, 'missed'))) for x in sorted(sg[sc], key=lambda x: int(x['run'])))
        print(f"| {sc} | {r['refresh_hz']} | {r['frames']} | {r['drops']} | {r['missed']} | {r['gap_p50_ms']} | {r['gap_p99_ms']} | {r['gap_max_ms']} | {r['cb_late_p99_ms']} | {ev} | {evp} | {r['worst_iter_ms']} ({r['worst_iter_vm_ms']}, {r['worst_iter_gcpark_ms']}) | {r['stuck_reports']} | {per} |")
    print("\n## Scenario extras (same median runs)\n")
    for sc in order:
        if sc not in sg: continue
        r = median_run(sg[sc])
        keys = ['turns', 'ui_only_turns', 'vm_main_ms', 'max_turn_ms', 'max_turn_kind', 'max_turn_gcpark_ms', 'max_turn_gcenter_ms',
                'timer_late_p99_ms', 'timer_late_max_ms', 'preemptions', 'overflows', 'gc_count',
                'ttsp_p50_ms', 'ttsp_p99_ms', 'ttsp_max_ms', 'stw_p50_ms', 'stw_p99_ms', 'stw_max_ms', 'main_enter_waits', 'main_enter_wait_max_ms',
                'ext_signals_per_s', 'counter_signals', 'rss_before_mb', 'rss_parked_mb', 'rss_per_process_kb',
                'hops', 'hops_per_s', 'hop_lat_p50_ms', 'hop_lat_p99_ms', 'hop_lat_max_ms', 'main_per_hop_p50_us', 'main_per_hop_p99_us',
                'sched_locks', 'sched_contended', 'sched_wait_ms', 'idle_ms', 'rss_mb']
        print(f"- **{sc}**: " + ", ".join(f"{x}={r[x]}" for x in keys if x in r))
PY
