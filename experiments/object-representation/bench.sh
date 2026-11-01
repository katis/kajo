#!/usr/bin/env bash
# Build orep-bench in two configurations (clean, timed) and run the matrix:
#   arith fib sends alloc ivars walk walkbuild  x  A B C  x  1, 8 workers
#   become reshape compact snapshot             x  A B C  x  8 workers (1 op + 7 fib)
# in both builds, RUNS interleaved runs each, then print medians.
#
# Builds:
#   O        swift build -c release (-O, whole module)
#   align32  the same plus LLVM -align-all-nofallthru-blocks=5, to control for
#            code placement (see ../vm-language-bench/RESULTS.md)
#
# Usage: ./bench.sh                (RUNS=5)
#        RUNS=1 KERNELS="walk" OPS="" ./bench.sh
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
RUNS=${RUNS:-5}
KERNELS=${KERNELS-"arith fib sends alloc ivars walk walkbuild"}
OPS=${OPS-"become reshape compact snapshot"}
VARIANTS=${VARIANTS:-"A B C"}
OUT=${OUT:-"$HERE/bench-raw.txt"}
export KAJO_SNAPSHOT_DIR="$HERE/swift/.build"

now() { python3 -c 'import time; print(time.time())'; }
timed() { # label, command...
    local label=$1; shift
    local t0 t1
    t0=$(now)
    "$@" >/dev/null 2>&1
    t1=$(now)
    python3 -c "print(f'build  {\"$label\":<24} {($t1 - $t0):6.1f} s')"
}

echo "== clean release builds"
rm -rf swift/.build
timed "O (-O, WMO)" swift build -c release --package-path swift --product orep-bench
timed "align32" swift build -c release --package-path swift --product orep-bench \
    --scratch-path swift/.build/align -Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5
declare -a BUILDS=(
    "O|swift/.build/release/orep-bench"
    "align32|swift/.build/align/release/orep-bench"
)

echo "== matrix: kernels=[$KERNELS] ops=[$OPS] variants=[$VARIANTS] runs=$RUNS"
{
    echo "# machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.perflevel0.physicalcpu) P-cores + $(sysctl -n hw.perflevel1.physicalcpu) E-cores, no pinning"
    echo "# $(swift --version 2>&1 | head -1)"
} > "$OUT"
for run in $(seq 1 "$RUNS"); do
    for k in $KERNELS; do
        for n in 1 8; do
            for b in "${BUILDS[@]}"; do
                for v in $VARIANTS; do
                    echo "build=${b%%|*} run=$run $("${b#*|}" "$v" "$k" "$n")" >> "$OUT"
                done
            done
        done
    done
    for k in $OPS; do
        for b in "${BUILDS[@]}"; do
            for v in $VARIANTS; do
                echo "build=${b%%|*} run=$run $("${b#*|}" "$v" "$k" 8)" >> "$OUT"
            done
        done
    done
    echo "   run $run/$RUNS done"
done
rm -f "$HERE"/swift/.build/snapshot-*.img

python3 - "$OUT" <<'PY'
import sys, statistics as st, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    if line.startswith('#'):
        print(line.strip()); continue
    kv = dict(t.split('=', 1) for t in line.split())
    rows[(kv['kernel'], kv['build'], kv['variant'], int(kv['workers']))].append(kv)

def med(key, field, default=None):
    vals = [float(r[field]) for r in rows.get(key, []) if field in r]
    return st.median(vals) if vals else default

builds = ['align32', 'O']
variants = ['A', 'B', 'C']
kernels = [k for k in ['arith', 'fib', 'sends', 'alloc', 'ivars', 'walk', 'walkbuild']
           if any(key[0] == k for key in rows)]
ops = [k for k in ['become', 'reshape', 'compact', 'snapshot'] if any(key[0] == k for key in rows)]

def equal(k, n):
    sums = {r['checksum'] for (kk, b, v, nn), rs in rows.items() if kk == k and nn == n for r in rs}
    return ('yes' if len(sums) == 1 else 'NO'), sorted(sums)[0]

print("\n## Kernels: median wall ms (5 runs), ratio to A, checksum agreement across all variants and builds\n")
print("| kernel | workers | build | A ms | B ms | C ms | B/A | C/A | checksum | equal |")
print("|---|--:|---|--:|--:|--:|--:|--:|---|:-:|")
for k in kernels:
    for n in (1, 8):
        eq, cs = equal(k, n)
        for b in builds:
            m = {v: med((k, b, v, n), 'ms') for v in variants}
            if m['A'] is None: continue
            f = lambda x: f"{x:.1f}" if x is not None else "-"
            r = lambda x: f"{x / m['A']:.2f}" if x is not None else "-"
            print(f"| {k} | {n} | {b} | {f(m['A'])} | {f(m['B'])} | {f(m['C'])} | {r(m['B'])} | {r(m['C'])} | {cs} | {eq} |")

print("\n## Scaling 1 -> 8 workers (median ms ratio) and allocation-buffer refills (8 workers)\n")
print("| kernel | build | A | B | C | tlab refills | B entry refills | GCs |")
print("|---|---|--:|--:|--:|--:|--:|--:|")
for k in kernels:
    for b in builds:
        sp = {}
        for v in variants:
            a1, a8 = med((k, b, v, 1), 'ms'), med((k, b, v, 8), 'ms')
            sp[v] = f"{a1 / a8:.2f}x" if a1 and a8 else "-"
        tl = med((k, b, 'B', 8), 'tlabRefills', 0)
        er = med((k, b, 'B', 8), 'entryRefills', 0)
        gc = med((k, b, 'A', 8), 'gcCount', 0)
        print(f"| {k} | {b} | {sp['A']} | {sp['B']} | {sp['C']} | {tl:.0f} | {er:.0f} | {gc:.0f} |")

print("\n## Peak RSS (MB, 1 worker)\n")
print("| kernel | A | B | C |")
print("|---|--:|--:|--:|")
for k in ['walk', 'walkbuild', 'alloc']:
    if (k, 'align32', 'A', 1) in rows:
        print(f"| {k} | " + " | ".join(f"{med((k, 'align32', v, 1), 'rss_mb', 0):.0f}" for v in variants) + " |")

def optable(k, fields, title):
    if k not in ops: return
    print(f"\n## {title} (8 workers: 1 operating + 7 running fib; medians)\n")
    print("| build | variant | " + " | ".join(name for name, _ in fields) + " | checksum |")
    print("|---|---|" + "--:|" * len(fields) + "---|")
    for b in builds:
        for v in variants:
            key = (k, b, v, 8)
            if key not in rows: continue
            cells = []
            for name, fn in fields:
                try:
                    x = fn(lambda f, d=0.0: med(key, f, d))
                    cells.append(x if isinstance(x, str) else (f"{x:.3f}" if abs(x) < 10 else f"{x:.1f}"))
                except ZeroDivisionError:
                    cells.append("-")
            cs = sorted({r['checksum'] for r in rows[key]})
            print(f"| {b} | {v} | " + " | ".join(cells) + f" | {cs[0]}{'' if len(cs) == 1 else ' (varies!)'} |")

optable('become', [
    ('2-way becomes', lambda m: f"{m('becomeCount'):.0f}"),
    ('fwd path', lambda m: f"{m('becomeFwdPath'):.0f}"),
    ('op us/become', lambda m: 1000 * m('becomeOp_ms') / m('becomeCount')),
    ('pause us/become', lambda m: 1000 * m('becomeStw_ms') / m('becomeCount')),
    ('wall us/become', lambda m: 1000 * m('becomeWall_ms') / m('becomeCount')),
    ('bulk fwd pairs', lambda m: f"{m('forwardPairs'):.0f}"),
    ('bulk op ms', lambda m: m('forwardOp_ms')),
    ('bulk pause ms', lambda m: m('forwardStw_ms')),
    ('GC before ms', lambda m: m('gc1_ms')),
    ('GC after ms', lambda m: m('gc2_ms')),
    ('cleanup extra ms', lambda m: m('gc2_ms') - m('gc1_ms')),
    ('ttsp us/stop', lambda m: 1000 * m('ttsp_ms') / m('stwCount')),
    ('parked ms (7 workers)', lambda m: m('parked_ms')),
], "become: 2^20 live objects, 10 000 two-way becomes, one bulk becomeForward of 100 000")

optable('reshape', [
    ('instances', lambda m: f"{m('reshapeCount'):.0f}"),
    ('op ms', lambda m: m('reshapeOp_ms')),
    ('pause ms', lambda m: m('reshapeStw_ms')),
    ('GC before ms', lambda m: m('gc1_ms')),
    ('GC after ms', lambda m: m('gc2_ms')),
    ('pause + GC after ms', lambda m: m('reshapeStw_ms') + m('gc2_ms')),
    ('parked ms', lambda m: m('parked_ms')),
], "reshape: add an instance variable to a class with 2^20 instances")

optable('compact', [
    ('GC mark ms', lambda m: m('gc3Mark_ms')),
    ('GC sweep ms', lambda m: m('gc3Sweep_ms')),
    ('cmp mark ms', lambda m: m('compactMark_ms')),
    ('plan ms', lambda m: m('compactPlan_ms')),
    ('update ms', lambda m: m('compactUpdate_ms')),
    ('move ms', lambda m: m('compactMove_ms')),
    ('entry sweep ms', lambda m: m('compactSweep_ms')),
    ('compaction pause ms', lambda m: m('compactStw_ms')),
    ('update/(update+move)', lambda m: m('compactUpdate_ms') / (m('compactUpdate_ms') + m('compactMove_ms'))),
    ('MB moved', lambda m: m('compactBytesMoved') / 2**20),
    ('MB live', lambda m: m('compactLiveBytes') / 2**20),
    ('slots updated', lambda m: f"{m('compactSlotsUpdated'):.0f}"),
    ('parked ms', lambda m: m('parked_ms')),
], "compact: 2^21 allocated, every other one dead")

optable('snapshot', [
    ('save ms', lambda m: m('snapSave_ms')),
    ('MB', lambda m: m('snapBytes') / 2**20),
    ('load ms', lambda m: m('snapLoad_ms')),
    ('of which reloc ms', lambda m: m('snapReloc_ms')),
    ('slots relocated', lambda m: f"{m('snapRelocSlots'):.0f}"),
    ('root words relocated', lambda m: f"{m('snapRelocRoots'):.0f}"),
    ('heap words changed by load', lambda m: f"{m('snapWordsChanged'):.0f}"),
    ('table entries scanned', lambda m: f"{m('snapEntriesScanned'):.0f}"),
    ('reload ok', lambda m: f"{m('reload_ok'):.0f}"),
    ('parked ms', lambda m: m('parked_ms')),
], "snapshot: the walk graph (2^22 nodes), saved at a safepoint, loaded at a new base")
PY
