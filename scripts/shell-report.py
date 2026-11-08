#!/usr/bin/env python3
"""Module 9a: tables from shell-matrix.sh results (docs/modules/shells.md).

    scripts/shell-report.py <outdir>
    scripts/shell-report.py --bar <outdir>

Reads golden.txt, scenarios.txt, events.txt, hog.txt and drift.txt (one
`key=value` line per launch) and prints markdown tables: medians over the
runs with the range in brackets.

--bar (gate tiers, docs/modules/gate-tiers.md) tabulates the bar's columns
over every raw row instead (AGENTS.md: after any device run, tabulate the
bar's columns over every row): launches failed, golden checksums, frames
missed, fallbacks and the longest stop (from gc_stopsByKind) per file and in
all, and the rows that missed a frame, fell back or delivered no frames
(a display asleep). Exit status 1 when a launch failed or a checksum
disagreed, 0 otherwise (missed frames and fallbacks are reported, not
judged)."""
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


def longest_stop(r):
    """(ms, kind) of the longest stop in a row's gc_stopsByKind
    (kind:count/max ms/ttsp max ms, comma separated), or None."""
    best = None
    for part in r.get("gc_stopsByKind", "-").split(","):
        if ":" not in part:
            continue
        kind, rest = part.split(":", 1)
        fields = rest.split("/")
        ms = num(fields[1]) if len(fields) > 1 else None
        if ms is not None and (best is None or ms > best[0]):
            best = (ms, kind)
    return best


def kind_stops(r, kind):
    """(count, max ms) of one stop kind in a row's gc_stopsByKind (the
    sweep stop's `sweep`, docs/modules/sweep-stop.md), (0, None) when the
    row has none."""
    for part in r.get("gc_stopsByKind", "-").split(","):
        if part.startswith(kind + ":"):
            fields = part.split(":", 1)[1].split("/")
            return int(num(fields[0]) or 0), num(fields[1]) if len(fields) > 1 else None
    return 0, None


def row_name(r):
    keys = ["mode", "kernel", "kind", "workers", "scenario", "young", "events", "hog", "budget", "run"]
    return " ".join(f"{k}={r[k]}" for k in keys if k in r)


def bar(d):
    files = ["drift", "golden", "scenarios", "events", "hog"]
    print("| file | rows | launches failed | checksums not ok | rows missing frames | frames missed | rows with no frames | rows falling back | fallbacks | sweep stops (longest ms) | longest stop ms |")
    print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|")
    tot = defaultdict(float)
    worst = None
    notes = []
    for f in files:
        rows = lines(d / f"{f}.txt")
        if not rows:
            continue
        failed = sum(1 for r in rows if r.get("_failed"))
        ok_rows = [r for r in rows if not r.get("_failed")]
        notok = lambda r: r.get("ok") == "0" or r.get("checksum", "").startswith("error:")  # ok=-1: no published checksum at that worker count
        bad_sum = sum(1 for r in ok_rows if notok(r))
        framed = [r for r in ok_rows if "missed" in r]
        missing = [r for r in framed if (num(r.get("missed")) or 0) > 0]
        missed = sum(num(r.get("missed")) or 0 for r in framed)
        noframes = [r for r in framed if (num(r.get("frames")) or 0) == 0]
        falling = [r for r in ok_rows if (num(r.get("gc_fallbacks")) or 0) > 0]
        fallbacks = sum(num(r.get("gc_fallbacks")) or 0 for r in ok_rows)
        sweeps = [kind_stops(r, "sweep") for r in ok_rows]
        sweep_n = sum(n for n, _ in sweeps)
        sweep_max = max([m for _, m in sweeps if m is not None], default=None)
        if sweep_max is not None:
            tot["sweepmax"] = max(tot["sweepmax"], sweep_max)
        fw = None
        for r in ok_rows:
            s = longest_stop(r)
            if s and (fw is None or s[0] > fw[0]):
                fw = (s[0], s[1], r)
        if fw and (worst is None or fw[0] > worst[0]):
            worst = (fw[0], fw[1], fw[2], f)
        for k, v in [("rows", len(rows)), ("failed", failed), ("sums", bad_sum), ("missing", len(missing)), ("missed", missed),
                     ("noframes", len(noframes)), ("falling", len(falling)), ("fallbacks", fallbacks), ("sweeps", sweep_n)]:
            tot[k] += v
        stop = f"{fw[0]:.2f} ({fw[1]})" if fw else "-"
        sw = f"{sweep_n} ({sweep_max:.2f})" if sweep_max is not None else f"{sweep_n}"
        print(f"| {f} | {len(rows)} | {failed} | {bad_sum} | {len(missing)} | {missed:.0f} | {len(noframes)} | {len(falling)} | {fallbacks:.0f} | {sw} | {stop} |")
        for r in rows:
            if r.get("_failed"):
                notes.append(f"- {f}: launch failed: {' '.join(k + '=' + v for k, v in r.items() if not k.startswith('_'))}")
        for r in [r for r in ok_rows if notok(r)]:
            notes.append(f"- {f}: checksum ok={r.get('ok')}: {row_name(r)} checksum={r.get('checksum')}")
        for r in missing:
            notes.append(f"- {f}: missed {r.get('missed')} of {r.get('expected')}: {row_name(r)} fallbacks={r.get('gc_fallbacks', '-')} longest stop {longest_stop(r)}")
        for r in noframes:
            notes.append(f"- {f}: no frames delivered (display asleep?): {row_name(r)}")
        for r in falling:
            notes.append(f"- {f}: {r.get('gc_fallbacks')} fallbacks: {row_name(r)} record {r.get('gc_fallbackLog', '-')}")
    stop = f"{worst[0]:.2f} ({worst[1]}, {worst[3]}: {row_name(worst[2])})" if worst else "-"
    sw = f"{tot['sweeps']:.0f} ({tot['sweepmax']:.2f})" if tot["sweeps"] else "0"
    print(f"| all | {tot['rows']:.0f} | {tot['failed']:.0f} | {tot['sums']:.0f} | {tot['missing']:.0f} | {tot['missed']:.0f} | {tot['noframes']:.0f} | {tot['falling']:.0f} | {tot['fallbacks']:.0f} | {sw} | {stop} |")
    if notes:
        print()
        print("\n".join(notes))
    return 1 if tot["failed"] or tot["sums"] else 0


def main():
    if sys.argv[1] == "--bar":
        sys.exit(bar(Path(sys.argv[2])))
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
        print("| scenario | young | events | hog | budget | Hz | missed of expected | max gap ms | main stopped for others ms/10 s | own ms/10 s | acks other (mean µs) | ev lat p50 / p99 / max ms | stuck ms | preemptions | collector P share | marker P share | power W | peak MB | fallbacks | sweep stops (max ms) | thermal end |")
        print("|---|---|--:|--:|---|--:|---|--:|--:|--:|---|---|--:|--:|--:|--:|--:|--:|--:|--:|---|")
        for key, rs in g.items():
            s, y, e, h, b = key
            exp = med(rs, "expected", "{:.0f}", False)
            ev = "-" if e == "0" else f"{med(rs, 'ev_lat_p50_ms', '{:.3f}')} / {med(rs, 'ev_lat_p99_ms', '{:.2f}')} / {med(rs, 'ev_lat_max_ms', '{:.1f}')}"
            th = ",".join(sorted({r.get("thermal_end", "-") for r in rs}))
            for r in rs:
                n, m = kind_stops(r, "sweep")
                r["_sweeps"], r["_sweepmax"] = n, m
            sw = f"{med(rs, '_sweeps', '{:.0f}')} ({med(rs, '_sweepmax', '{:.2f}', False)})"
            print(f"| {s} | {y} | {e} | {h} | {b} | {med(rs, 'refresh_hz', '{:.0f}', False)} | {med(rs, 'missed', '{:.0f}')} of {exp} | {med(rs, 'gap_max_ms')} | "
                  f"{med(rs, 'main_stopped_others_ms_per10s')} | {med(rs, 'main_stopped_own_ms_per10s')} | {med(rs, 'main_acks_other', '{:.0f}')} ({med(rs, 'main_ack_other_mean_us', '{:.0f}', False)}) | {ev} | "
                  f"{med(rs, 'stuck_ms', '{:.0f}') if h == '1' else '-'} | {med(rs, 'preemptions', '{:.0f}')} | {med(rs, 'collector_p_frac', '{:.2f}')} | {med(rs, 'marker_p_frac', '{:.2f}')} | "
                  f"{med(rs, 'power_w', '{:.1f}')} | {med(rs, 'footprint_peak_mb', '{:.0f}')} | {med(rs, 'gc_fallbacks', '{:.0f}')} | {sw} | {th} |")
        print()

    dr = lines(d / "drift.txt")
    if dr:
        print("### drift (fib, 1 worker)\n")
        for tag, rs in group(dr, ["tag"]).items():
            print(f"- {tag[0]}: {med(rs, 'ms', '{:.0f}')} ms, thermal {','.join(r.get('thermal', '-') for r in rs)}")


main()
