#!/usr/bin/env python3
"""Module 9a: tables from shell-matrix.sh results (docs/modules/shells.md).

    scripts/shell-report.py <outdir>

Reads golden.txt, scenarios.txt, events.txt, hog.txt and drift.txt (one
`key=value` line per launch) and prints markdown tables: medians over the
runs with the range in brackets."""
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def lines(path):
    out = []
    if not path.exists():
        return out
    for raw in path.read_text().splitlines():
        d = {}
        for tok in raw.split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                d.setdefault(k, v)
        if "FAILED" in d:
            d["_failed"] = True
        if "summary" in d or "start" in d:
            continue
        out.append(d)
    return out


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def med(rows, key, fmt="{:.1f}", rng=True):
    xs = [num(r.get(key)) for r in rows]
    xs = [x for x in xs if x is not None]
    if not xs:
        return "-"
    m = statistics.median(xs)
    s = fmt.format(m)
    if rng and len(xs) > 1 and min(xs) != max(xs):
        s += " [" + fmt.format(min(xs)) + "–" + fmt.format(max(xs)) + "]"
    return s


def group(rows, keys):
    g = defaultdict(list)
    for r in rows:
        if r.get("_failed"):
            continue
        g[tuple(r.get(k, "-") for k in keys)].append(r)
    return g


def main():
    d = Path(sys.argv[1])
    fails = sum(1 for f in ["golden", "scenarios", "events", "hog", "drift"] for r in lines(d / f"{f}.txt") if r.get("_failed"))
    print(f"launches failed: {fails}\n")

    g = group(lines(d / "golden.txt"), ["kind", "kernel", "workers"])
    if g:
        print("| kernel | workers | checksum ok | ms | thermal |")
        print("|---|--:|---|--:|---|")
        for (kind, k, w), rs in sorted(g.items(), key=lambda x: (x[0][0], x[0][1], int(x[0][2]))):
            oks = {r.get("ok") for r in rs}
            sums = {r.get("checksum") for r in rs}
            ok = "yes" if oks == {"1"} else ("same in every run" if len(sums) == 1 and oks == {"-1"} else f"NO {oks} {sums}")
            th = ",".join(sorted({r.get("thermal", "-") for r in rs}))
            print(f"| {kind} {k} | {w} | {ok} | {med(rs, 'ms', '{:.0f}')} | {th} |")
        print()

    for name in ["scenarios", "events", "hog"]:
        g = group(lines(d / f"{name}.txt"), ["scenario", "young", "events", "hog", "budget"])
        if not g:
            continue
        print(f"### {name}\n")
        print("| scenario | young | events | hog | budget | Hz | missed of expected | max gap ms | main stopped for others ms/10 s | own ms/10 s | acks other (mean µs) | ev lat p50 / p99 / max ms | stuck ms | preemptions | collector P share | marker P share | power W | peak MB | thermal end |")
        print("|---|---|--:|--:|---|--:|---|--:|--:|--:|---|---|--:|--:|--:|--:|--:|--:|---|")
        for key, rs in g.items():
            s, y, e, h, b = key
            exp = med(rs, "expected", "{:.0f}", False)
            ev = "-" if e == "0" else f"{med(rs, 'ev_lat_p50_ms', '{:.3f}')} / {med(rs, 'ev_lat_p99_ms', '{:.2f}')} / {med(rs, 'ev_lat_max_ms', '{:.1f}')}"
            th = ",".join(sorted({r.get("thermal_end", "-") for r in rs}))
            print(f"| {s} | {y} | {e} | {h} | {b} | {med(rs, 'refresh_hz', '{:.0f}', False)} | {med(rs, 'missed', '{:.0f}')} of {exp} | {med(rs, 'gap_max_ms')} | "
                  f"{med(rs, 'main_stopped_others_ms_per10s')} | {med(rs, 'main_stopped_own_ms_per10s')} | {med(rs, 'main_acks_other', '{:.0f}')} ({med(rs, 'main_ack_other_mean_us', '{:.0f}', False)}) | {ev} | "
                  f"{med(rs, 'stuck_ms', '{:.0f}') if h == '1' else '-'} | {med(rs, 'preemptions', '{:.0f}')} | {med(rs, 'collector_p_frac', '{:.2f}')} | {med(rs, 'marker_p_frac', '{:.2f}')} | "
                  f"{med(rs, 'power_w', '{:.1f}')} | {med(rs, 'footprint_peak_mb', '{:.0f}')} | {th} |")
        print()

    dr = lines(d / "drift.txt")
    if dr:
        print("### drift (fib, 1 worker)\n")
        for tag, rs in group(dr, ["tag"]).items():
            print(f"- {tag[0]}: {med(rs, 'ms', '{:.0f}')} ms, thermal {','.join(r.get('thermal', '-') for r in rs)}")


main()
