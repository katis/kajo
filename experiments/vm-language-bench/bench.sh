#!/usr/bin/env bash
# Build both implementations in every flag variant (clean, timed) and run the
# full matrix: 4 kernels x 6 variants x {1, 8} workers, RUNS runs each
# (interleaved), then print median wall time, 1->8 speedup, GC cycles and
# whether checksums agree across all variants.
#
# Usage: ./bench.sh            (RUNS=5 by default)
#        RUNS=3 KERNELS="arith fib" ./bench.sh
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
RUNS=${RUNS:-5}
KERNELS=${KERNELS:-"arith fib sends alloc"}
WORKERS=${WORKERS:-"1 8"}
OUT=${OUT:-"$HERE/bench-raw.txt"}

now() { python3 -c 'import time; print(time.time())'; }
timed() { # label, command...
    local label=$1; shift
    local t0 t1
    t0=$(now)
    "$@" >/dev/null 2>&1
    t1=$(now)
    python3 -c "print(f'build  {\"$label\":<28} {($t1 - $t0):6.1f} s')"
}

echo "== clean release builds"
rm -rf rust/target swift/.build
timed "rust (release)" cargo build --release --manifest-path rust/Cargo.toml
RUSTFLAGS="-C target-cpu=native" timed "rust (target-cpu=native)" \
    cargo build --release --manifest-path rust/Cargo.toml --target-dir rust/target/native
timed "swift (-O, WMO)" swift build -c release --package-path swift
timed "swift (-Ounchecked, excl=unchk)" swift build -c release --package-path swift \
    --scratch-path swift/.build/unchecked \
    -Xswiftc -Ounchecked -Xswiftc -enforce-exclusivity=unchecked
# Layout-control variants: same flags as the defaults plus LLVM's
# -align-all-nofallthru-blocks=5 (32-byte aligned branch targets). Added after
# finding that swift -O and -Ounchecked emit an identical dispatch loop yet
# differ by ~20% (see RESULTS.md).
RUSTFLAGS="-C llvm-args=-align-all-nofallthru-blocks=5" timed "rust (align32)" \
    cargo build --release --manifest-path rust/Cargo.toml --target-dir rust/target/align
timed "swift (-O, align32)" swift build -c release --package-path swift \
    --scratch-path swift/.build/align \
    -Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5

declare -a VARIANTS=(
    "rust|rust/target/release/kajo-bench"
    "rust-native|rust/target/native/release/kajo-bench"
    "swift-O|swift/.build/release/kajo-bench"
    "swift-Ounchecked|swift/.build/unchecked/release/kajo-bench"
    "rust-align32|rust/target/align/release/kajo-bench"
    "swift-O-align32|swift/.build/align/release/kajo-bench"
)

echo "== running matrix: kernels=[$KERNELS] workers=[$WORKERS] runs=$RUNS"
echo "# machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.perflevel0.physicalcpu) P-cores + $(sysctl -n hw.perflevel1.physicalcpu) E-cores, no pinning" > "$OUT"
for run in $(seq 1 "$RUNS"); do
    for k in $KERNELS; do
        for n in $WORKERS; do
            for v in "${VARIANTS[@]}"; do
                name=${v%%|*}
                bin=${v#*|}
                line=$("$bin" "$k" "$n" "$HERE/kernels")
                echo "variant=$name run=$run $line" >> "$OUT"
            done
        done
    done
    echo "   run $run/$RUNS done"
done

python3 - "$OUT" <<'PY'
import sys, statistics, collections
rows = collections.defaultdict(list)
order = []
for line in open(sys.argv[1]):
    if line.startswith('#'):
        print(line.strip()); continue
    kv = dict(t.split('=', 1) for t in line.split())
    key = (kv['kernel'], kv['variant'], int(kv['workers']))
    if key not in rows: order.append(key)
    rows[key].append(kv)
med = {k: statistics.median(float(r['ms']) for r in v) for k, v in rows.items()}
sums = collections.defaultdict(set)
for (k, var, n), v in rows.items():
    for r in v: sums[(k, n)].add(r['checksum'])
print()
print(f"| kernel | variant          | workers | median ms | min ms | speedup 1->8 | GC cycles | checksum | equal |")
print(f"|--------|------------------|--------:|----------:|-------:|-------------:|----------:|----------|:-----:|")
kernels = list(dict.fromkeys(k for k, _, _ in order))
variants = list(dict.fromkeys(v for _, v, _ in order))
for k in kernels:
    for var in variants:
        for n in sorted({n for kk, vv, n in order if kk == k and vv == var}):
            v = rows[(k, var, n)]
            gcs = sorted({int(r['gc']) for r in v})
            gc = str(gcs[0]) if len(gcs) == 1 else f"{gcs[0]}-{gcs[-1]}"
            sp = ''
            if n != 1 and (k, var, 1) in med:
                sp = f"{med[(k, var, 1)] / med[(k, var, n)]:.2f}x"
            cs = sorted({r['checksum'] for r in v})
            eq = 'yes' if len(sums[(k, n)]) == 1 else 'NO'
            mn = min(float(r['ms']) for r in v)
            print(f"| {k:<6} | {var:<16} | {n:>7} | {med[(k, var, n)]:>9.1f} | {mn:>6.1f} | {sp:>12} | {gc:>9} | {cs[0]:<8} | {eq:^5} |")
print()
print("Swift / Rust median ratio (same workers; >1 means Swift slower):")
for k in kernels:
    for n in sorted({n for kk, _, n in order if kk == k}):
        r = med.get((k, 'rust', n)); 
        parts = []
        for var in variants:
            if var.startswith('swift') and r and (k, var, n) in med:
                parts.append(f"{var} {med[(k, var, n)] / r:.2f}")
        rn = med.get((k, 'rust-native', n))
        if r and rn: parts.append(f"rust-native {rn / r:.2f}")
        ra, sa = med.get((k, 'rust-align32', n)), med.get((k, 'swift-O-align32', n))
        if ra and sa: parts.append(f"swift-O-align32/rust-align32 {sa / ra:.2f}")
        print(f"  {k:<6} w={n}: " + ", ".join(parts))
PY
