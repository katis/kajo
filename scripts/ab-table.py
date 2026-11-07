#!/usr/bin/env python3
"""The aligned A/B's table (scripts/ab.sh): median and range of ms per
kernel and worker count for the base ("start") and the working tree
("head"), the ratio, cycles per send and the cycles and instructions
ratios, and whether every checksum agreed. Exit status 1 when a checksum
differs between the sides or a side has no rows.

    scripts/ab-table.py <bench.txt>"""
import collections
import statistics
import sys

rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    if line.startswith("#"):
        continue
    kv = dict(t.split("=", 1) for t in line.split() if "=" in t)
    if not kv.get("ms"):
        continue
    rows[(kv["kernel"], int(kv["workers"]), kv["side"])].append(kv)


def med(rs, f):
    xs = [float(r[f]) for r in rs if r.get(f)]
    return statistics.median(xs) if xs else None


def ratio(a, b):
    return f"{b / a:.3f}" if a and b else "-"


bad = 0
print("| kernel | workers | base ms | head ms | ratio | base cycles/send | head cycles/send | cycles ratio | instructions ratio | checksums |")
print("|---|--:|--:|--:|--:|--:|--:|--:|--:|---|")
for k, w in sorted({(k, w) for k, w, _ in rows}):
    a, b = rows.get((k, w, "start"), []), rows.get((k, w, "head"), [])
    if not a or not b:
        bad = 1
        print(f"| {k} | {w} | {'-' if not a else len(a)} | {'-' if not b else len(b)} | - | | | | | MISSING |")
        continue
    ma, mb = med(a, "ms"), med(b, "ms")
    rng = lambda rs: f"{min(float(r['ms']) for r in rs):.0f}-{max(float(r['ms']) for r in rs):.0f}"
    sa, sb = med(a, "sends"), med(b, "sends")
    ca, cb = med(a, "cycles"), med(b, "cycles")
    ia, ib = med(a, "instructions"), med(b, "instructions")
    cps = lambda c, s: f"{c / s:.1f}" if c and s and s > 1000 else "-"
    sums = {r["checksum"] for r in a + b}
    if len(sums) != 1:
        bad = 1
    print(f"| {k} | {w} | {ma:.1f} ({rng(a)}) | {mb:.1f} ({rng(b)}) | **{mb / ma:.3f}** | {cps(ca, sa)} | {cps(cb, sb)} | {ratio(ca, cb)} | {ratio(ia, ib)} | {'same' if len(sums) == 1 else 'DIFF ' + ','.join(sorted(sums))} |")
sys.exit(bad)
