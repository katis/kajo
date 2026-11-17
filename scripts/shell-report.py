#!/usr/bin/env python3
"""Module 9a: tables from shell-matrix.sh results (docs/modules/shells.md).

    scripts/shell-report.py <outdir>
    scripts/shell-report.py --bar <outdir>

Reads golden.txt, scenarios.txt, events.txt, hog.txt, mainload.txt and
drift.txt (one `key=value` line per launch) and prints markdown tables:
medians over the runs with the range in brackets. Any other *.txt file of
result rows (lines that start with `mode=` after the wall clock, or FAILED
lines) is a row kind the report does not know: both outputs name it, and
--bar tabulates it as "<name> (UNKNOWN kind)" so its rows are counted,
never dropped.

--bar (gate tiers, docs/modules/gate-tiers.md) tabulates the bar's columns
over every raw row instead (AGENTS.md: after any device run, tabulate the
bar's columns over every row): launches failed, golden checksums, frames
missed, fallbacks and the longest stop (from gc_stopsByKind) per file and in
all, and the rows that missed a frame, fell back or delivered no frames
(a display asleep). Exit status 1 when a launch failed or a checksum
disagreed, 0 otherwise (missed frames and fallbacks are reported, not
judged).

The main worker always offloads (docs/modules/main-offload.md): --bar adds
the young collections that ran on the main thread (gc_ycOnMain, its longest
gc_ycOnMainMaxMs; 0 in every row but the stw rows, whose value is "-") and
the host's nursery's collections (gc_ycHost, gc_ycHostMaxMs), and a line
naming every young mode the rows carry: stw and offload, and any other
value counted as unknown (never as a pass or a failure). Rows without the
counter read "?" in those columns.

The main worker's flips under load (docs/modules/main-flips.md): the
mainload rows (the storm with the frame action allocating enough to flip
the main worker's nursery a hundred times or more a launch, offload and the
stw control) get a table of their own and a per-launch table; --bar adds
two columns over every row: the main worker's flips in the window
(main_flips) and its waits for its collector in the window
(main_collector_waits, the longest main_collector_wait_max_ms). Rows
without the fields read "?"; a row whose whole-run count
(gc_ycMainCollectorWaits, warm-up included) is above the window's is named
in the notes, as is every row with a wait.

The warm-up launch (docs/modules/first-launch.md): shell-matrix.sh runs one
idle launch before its first row into warmup.txt; it is never a row of a
table or of the bar, and both outputs print it on a line of its own before
the tables (frames missed, the longest gap and where it starts in the
window) when the file exists, so its effect stays visible."""
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
    (kind:count/max ms/ttsp max ms/last parker/via, comma separated; the
    last two name who parked last in the stop with that wait and are absent
    on rows from before 2026-11-13), or None."""
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


def longest_wait(r):
    """(ms, kind, last parker) of the longest time to safepoint in a row's
    gc_stopsByKind, or None. The parker is "?" on a row written before the
    field existed and "-" when the stop had nobody to wait for."""
    best = None
    for part in r.get("gc_stopsByKind", "-").split(","):
        if ":" not in part:
            continue
        kind, rest = part.split(":", 1)
        fields = rest.split("/")
        ms = num(fields[2]) if len(fields) > 2 else None
        who = "/".join(fields[3:5]) if len(fields) > 4 else "?"
        if ms is not None and (best is None or ms > best[0]):
            best = (ms, kind, "-" if who == "-/-" else who)
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


YOUNG_MODES = {"stw": "the oracle", "offload": "the policy"}


def young_modes(rows_by_file):
    """One line naming every young mode the scenario rows carry, with row
    counts: the known ones, the rest as unknown."""
    count = defaultdict(int)
    for rows in rows_by_file:
        for r in rows:
            if r.get("mode") == "scenario" or "scenario" in r:
                count[r.get("young", "-")] += 1
    if not count:
        return None
    parts = []
    for y in sorted(count):
        what = YOUNG_MODES.get(y, "UNKNOWN young mode")
        parts.append(f"{y} {count[y]} ({what})")
    return "young modes in the rows: " + ", ".join(parts)


def on_main(rows):
    """(collections on the main thread, longest ms, rows with the counter,
    stw rows, rows without it) over rows; and the host's (collections,
    longest ms)."""
    n = 0.0
    mx = None
    have = stw = absent = 0
    hn = 0.0
    hmx = None
    for r in rows:
        v = r.get("gc_ycOnMain")
        if v is None:
            absent += 1
            continue
        if v == "-":
            stw += 1
            continue
        have += 1
        n += num(v) or 0
        m = num(r.get("gc_ycOnMainMaxMs"))
        if m is not None and (num(v) or 0) > 0:
            mx = m if mx is None else max(mx, m)
        hn += num(r.get("gc_ycHost")) or 0
        hm = num(r.get("gc_ycHostMaxMs"))
        if hm is not None and (num(r.get("gc_ycHost")) or 0) > 0:
            hmx = hm if hmx is None else max(hmx, hm)
    return n, mx, have, stw, absent, hn, hmx


KNOWN_FILES = ["drift", "golden", "scenarios", "events", "hog", "mainload"]


def unknown_files(d):
    """The *.txt files of result rows that are no known row kind (not the
    warm-up, not a device's console log or a served-requests file)."""
    out = []
    for p in sorted(Path(d).glob("*.txt")):
        name = p.stem
        if name in KNOWN_FILES or name == "warmup" or name.startswith("requests-") or name.endswith("-console"):
            continue
        text = p.read_text(errors="replace")
        if any(" mode=" in l or l.startswith("mode=") or l.startswith("FAILED=") for l in text.splitlines()):
            out.append(name)
    return out


def flips_waits(rows):
    """(main flips, waits for the collector, longest wait ms or None, rows
    with the fields) over rows, window values (main_flips,
    main_collector_waits, main_collector_wait_max_ms)."""
    flips = waits = 0.0
    mx = None
    have = 0
    for r in rows:
        if "main_flips" not in r:
            continue
        have += 1
        flips += num(r.get("main_flips")) or 0
        n = num(r.get("main_collector_waits")) or 0
        waits += n
        m = num(r.get("main_collector_wait_max_ms"))
        if n > 0 and m is not None:
            mx = m if mx is None else max(mx, m)
    return flips, waits, mx, have


def row_name(r):
    keys = ["mode", "kernel", "kind", "workers", "scenario", "young", "events", "hog", "budget", "mainalloc", "mainwork", "run"]
    return " ".join(f"{k}={r[k]}" for k in keys if k in r)


def warmup_line(d):
    """The warm-up launch's numbers on one line, or None without one."""
    rows = lines(d / "warmup.txt")
    if not rows:
        return None
    parts = []
    for r in rows:
        if r.get("_failed"):
            parts.append("launch failed")
        else:
            parts.append(f"missed {r.get('missed', '-')} of {r.get('expected', '-')}, max gap {r.get('gap_max_ms', '-')} ms"
                         f" at {r.get('gap_max_at_ms', '-')} ms of the window, gaps over 100 ms {r.get('gaps100', '-')}")
    return "warm-up launch (not a row): " + "; ".join(parts)


def bar(d):
    unknown = unknown_files(d)
    files = KNOWN_FILES + unknown
    w = warmup_line(d)
    if w:
        print(w)
        print()
    ym = young_modes([lines(d / f"{f}.txt") for f in files])
    if ym:
        print(ym)
        print()
    if unknown:
        print("row kinds this report does not know (tabulated as UNKNOWN, never dropped): " + ", ".join(f + ".txt" for f in unknown))
        print()
    print("| file | rows | launches failed | checksums not ok | rows missing frames | frames missed | rows with no frames | rows falling back | fallbacks | unjustified fallbacks | stalls (longest ms) | sweep stops (longest ms) | young on the main thread (longest ms) | host's nursery (longest ms) | main flips | main waits for the collector (longest ms) | longest stop ms | longest wait for a safepoint ms (kind, last parker/how it parked) |")
    print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|---|")
    tot = defaultdict(float)
    worst = None
    worst_wait = None
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
        # Allocation stalls: unjustified fallbacks (0 in every row; absent
        # on rows from before the module) and the stalls with the longest.
        unjust = sum(num(r.get("gc_unjustifiedFallbacks")) or 0 for r in ok_rows)
        stall_n = sum(num(r.get("gc_stalls")) or 0 for r in ok_rows)
        stall_max = max([num(r.get("gc_stallMaxMs")) or 0 for r in ok_rows if "gc_stallMaxMs" in r], default=None)
        if stall_max is not None:
            tot["stallmax"] = max(tot["stallmax"], stall_max)
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
        ww = None
        for r in ok_rows:
            s = longest_wait(r)
            if s and (ww is None or s[0] > ww[0]):
                ww = (s[0], s[1], s[2], r)
        if ww and (worst_wait is None or ww[0] > worst_wait[0]):
            worst_wait = (ww[0], ww[1], ww[2], ww[3], f)
        om_n, om_max, om_have, _, _, host_n, host_max = on_main(ok_rows)
        if om_max is not None:
            tot["onmainmax"] = max(tot["onmainmax"], om_max)
        if host_max is not None:
            tot["hostmax"] = max(tot["hostmax"], host_max)
        tot["onmainhave"] += om_have
        fl, wn, wmax, fw_have = flips_waits(ok_rows)
        tot["flips"] += fl
        tot["waits"] += wn
        tot["flipshave"] += fw_have
        if wmax is not None:
            tot["waitmax"] = max(tot["waitmax"], wmax)
        for k, v in [("rows", len(rows)), ("failed", failed), ("sums", bad_sum), ("missing", len(missing)), ("missed", missed),
                     ("noframes", len(noframes)), ("falling", len(falling)), ("fallbacks", fallbacks), ("sweeps", sweep_n),
                     ("unjust", unjust), ("stalls", stall_n), ("onmain", om_n), ("host", host_n)]:
            tot[k] += v
        stop = f"{fw[0]:.2f} ({fw[1]})" if fw else "-"
        sw = f"{sweep_n} ({sweep_max:.2f})" if sweep_max is not None else f"{sweep_n}"
        st = f"{stall_n:.0f} ({stall_max:.2f})" if stall_max is not None else "-"
        wait = f"{ww[0]:.2f} ({ww[1]}, {ww[2]})" if ww else "-"
        om = "?" if not om_have else (f"{om_n:.0f} ({om_max:.2f})" if om_max is not None else f"{om_n:.0f}")
        ho = "?" if not om_have else (f"{host_n:.0f} ({host_max:.2f})" if host_max is not None else f"{host_n:.0f}")
        flc = "?" if not fw_have else f"{fl:.0f}"
        wtc = "?" if not fw_have else (f"{wn:.0f} ({wmax:.2f})" if wmax is not None else f"{wn:.0f}")
        label = f if f in KNOWN_FILES else f"{f} (UNKNOWN kind)"
        print(f"| {label} | {len(rows)} | {failed} | {bad_sum} | {len(missing)} | {missed:.0f} | {len(noframes)} | {len(falling)} | {fallbacks:.0f} | {unjust:.0f} | {st} | {sw} | {om} | {ho} | {flc} | {wtc} | {stop} | {wait} |")
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
        for r in [r for r in ok_rows if (num(r.get("gc_unjustifiedFallbacks")) or 0) > 0]:
            notes.append(f"- {f}: UNJUSTIFIED fallbacks {r.get('gc_unjustifiedFallbacks')}: {row_name(r)} record {r.get('gc_fallbackLog', '-')}")
        for r in [r for r in ok_rows if (num(r.get("gc_ycOnMain")) or 0) > 0]:
            notes.append(f"- {f}: {r.get('gc_ycOnMain')} young collections on the main thread (longest {r.get('gc_ycOnMainMaxMs')} ms;"
                         f" worker 0's {r.get('gc_ycOnMainW0')}, the host's {r.get('gc_ycOnMainHost')}): {row_name(r)}")
        for r in [r for r in ok_rows if (num(r.get("main_collector_waits")) or 0) > 0]:
            notes.append(f"- {f}: {r.get('main_collector_waits')} waits of the main worker for its collector, {r.get('main_collector_wait_ms')} ms,"
                         f" longest {r.get('main_collector_wait_max_ms')} ms (flips {r.get('main_flips')}, missed {r.get('missed')},"
                         f" thermal {r.get('thermal_start', '-')}->{r.get('thermal_end', '-')}): {row_name(r)}")
        for r in ok_rows:
            run_w, win_w = num(r.get("gc_ycMainCollectorWaits")), num(r.get("main_collector_waits"))
            if run_w is not None and win_w is not None and run_w > win_w:
                notes.append(f"- {f}: {run_w - win_w:.0f} waits for the collector outside the window (whole run {r.get('gc_ycMainCollectorWaits')},"
                             f" longest {r.get('gc_ycMainCollectorWaitMaxMs')} ms): {row_name(r)}")
    stop = f"{worst[0]:.2f} ({worst[1]}, {worst[3]}: {row_name(worst[2])})" if worst else "-"
    sw = f"{tot['sweeps']:.0f} ({tot['sweepmax']:.2f})" if tot["sweeps"] else "0"
    stt = f"{tot['stalls']:.0f} ({tot['stallmax']:.2f})" if tot["stalls"] else "0"
    wait = f"{worst_wait[0]:.2f} ({worst_wait[1]}, {worst_wait[2]}, {worst_wait[4]}: {row_name(worst_wait[3])})" if worst_wait else "-"
    omt = "?" if not tot["onmainhave"] else (f"{tot['onmain']:.0f} ({tot['onmainmax']:.2f})" if tot["onmain"] else "0")
    hot = "?" if not tot["onmainhave"] else (f"{tot['host']:.0f} ({tot['hostmax']:.2f})" if tot["host"] else "0")
    flt = "?" if not tot["flipshave"] else f"{tot['flips']:.0f}"
    wtt = "?" if not tot["flipshave"] else (f"{tot['waits']:.0f} ({tot['waitmax']:.2f})" if tot["waits"] else "0")
    print(f"| all | {tot['rows']:.0f} | {tot['failed']:.0f} | {tot['sums']:.0f} | {tot['missing']:.0f} | {tot['missed']:.0f} | {tot['noframes']:.0f} | {tot['falling']:.0f} | {tot['fallbacks']:.0f} | {tot['unjust']:.0f} | {stt} | {sw} | {omt} | {hot} | {flt} | {wtt} | {stop} | {wait} |")
    if notes:
        print()
        print("\n".join(notes))
    if not tot["rows"]:
        # A matrix that died before its first row passes no bar (the review
        # fixes, part 2, item 11).
        print()
        print(f"- no rows in {d}: the matrix wrote nothing")
        return 1
    return 1 if tot["failed"] or tot["sums"] else 0


def mainload_tables(d):
    """The mainload rows: medians by young mode and load, then every launch
    (docs/modules/main-flips.md)."""
    rows = lines(d / "mainload.txt")
    if not rows:
        return
    print("### mainload (the storm, the main worker allocating on every frame)\n")
    print("| young | mainalloc | mainwork | runs | main flips | flip max ms | waits for the collector | wait ms | longest wait ms | offloaded collections (p50 / p99 ms) | frame turn p50 / p99 / max ms | busy frac | preempted turns of | missed of expected | fallbacks |")
    print("|---|--:|--:|--:|---|---|---|---|---|---|---|---|---|---|--:|")
    g = group(rows, ["young", "mainalloc", "mainwork"])
    for (y, a, w), rs in g.items():
        print(f"| {y} | {a} | {w} | {len(rs)} | {med(rs, 'main_flips', '{:.0f}')} | {med(rs, 'main_flip_max_ms', '{:.3f}')} | "
              f"{med(rs, 'main_collector_waits', '{:.0f}')} | {med(rs, 'main_collector_wait_ms', '{:.3f}')} | {med(rs, 'main_collector_wait_max_ms', '{:.3f}')} | "
              f"{med(rs, 'gc_ycOffloaded', '{:.0f}')} ({med(rs, 'gc_ycOffP50ms', '{:.2f}', False)} / {med(rs, 'gc_ycOffP99ms', '{:.2f}', False)}) | "
              f"{med(rs, 'turn_tick_p50_ms', '{:.2f}', False)} / {med(rs, 'turn_tick_p99_ms', '{:.2f}', False)} / {med(rs, 'turn_tick_max_ms', '{:.2f}', False)} | "
              f"{med(rs, 'main_busy_frac', '{:.3f}')} | {med(rs, 'preempted_turns', '{:.0f}', False)} of {med(rs, 'turns', '{:.0f}', False)} | "
              f"{med(rs, 'missed', '{:.0f}')} of {med(rs, 'expected', '{:.0f}', False)} | {med(rs, 'gc_fallbacks', '{:.0f}')} |")
    print()
    print("| young | run | flips | waits | wait ms | longest wait ms | offloaded | off p50 / p99 ms | turn p50 / p99 / max ms | busy frac | missed of expected | fallbacks | thermal start | thermal end |")
    print("|---|--:|--:|--:|--:|--:|--:|---|---|--:|---|--:|---|---|")
    for r in rows:
        if r.get("_failed"):
            print(f"| FAILED | {r.get('run', '-')} | | | | | | | | | | | | |")
            continue
        print(f"| {r.get('young', '-')} | {r.get('run', '-')} | {r.get('main_flips', '?')} | {r.get('main_collector_waits', '?')} | {r.get('main_collector_wait_ms', '?')} | "
              f"{r.get('main_collector_wait_max_ms', '?')} | {r.get('gc_ycOffloaded', '-')} | {r.get('gc_ycOffP50ms', '-')} / {r.get('gc_ycOffP99ms', '-')} | "
              f"{r.get('turn_tick_p50_ms', '-')} / {r.get('turn_tick_p99_ms', '-')} / {r.get('turn_tick_max_ms', '-')} | {r.get('main_busy_frac', '-')} | "
              f"{r.get('missed', '-')} of {r.get('expected', '-')} | {r.get('gc_fallbacks', '-')} | {r.get('thermal_start', '-')} | {r.get('thermal_end', '-')} |")
    print()


def main():
    if sys.argv[1] == "--bar":
        sys.exit(bar(Path(sys.argv[2])))
    d = Path(sys.argv[1])
    unknown = unknown_files(d)
    fails = sum(1 for f in KNOWN_FILES + unknown for r in lines(d / f"{f}.txt") if r.get("_failed"))
    print(f"launches failed: {fails}\n")
    if unknown:
        print("row kinds this report does not know (no table; --bar counts their rows): "
              + ", ".join(f"{f}.txt ({len(lines(d / (f + '.txt')))} rows)" for f in unknown) + "\n")
    w = warmup_line(d)
    if w:
        print(w + "\n")

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
        print("| scenario | young | events | hog | budget | Hz | missed of expected | max gap ms | main stopped for others ms/10 s | own ms/10 s | acks other (mean µs) | ev lat p50 / p99 / max ms | stuck ms | preemptions | collector P share | marker P share | power W | peak MB | fallbacks | stalls (max ms) | sweep stops (max ms) | thermal end |")
        print("|---|---|--:|--:|---|--:|---|--:|--:|--:|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|")
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
                  f"{med(rs, 'power_w', '{:.1f}')} | {med(rs, 'footprint_peak_mb', '{:.0f}')} | {med(rs, 'gc_fallbacks', '{:.0f}')} | "
                  f"{med(rs, 'gc_stalls', '{:.0f}')} ({med(rs, 'gc_stallMaxMs', '{:.1f}', False)}) | {sw} | {th} |")
        print()

    mainload_tables(d)

    dr = lines(d / "drift.txt")
    if dr:
        print("### drift (fib, 1 worker)\n")
        for tag, rs in group(dr, ["tag"]).items():
            print(f"- {tag[0]}: {med(rs, 'ms', '{:.0f}')} ms, thermal {','.join(r.get('thermal', '-') for r in rs)}")


main()
