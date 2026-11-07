#!/usr/bin/env python3
"""The performance report (docs/performance/README.md) from the raw files.

    scripts/perf-report.py [--raw FILE] [--slices FILE] [--device DIR]...
                           [--readme FILE] [--svg-dir DIR]

Reads the runtime comparison's raw runs (experiments/runtime-comparison/
bench-raw.txt, one key=value line per run under `# key: value` header
lines), the language experiment's raw lines (`just bench` with OUT set to
experiments/runtime-comparison/slices-raw.txt, so the experiment's own
published bench-raw.txt is not overwritten) and, when given, device matrix directories
(scripts/shell-matrix.sh's output: scenarios.txt, one line per launch).

Writes one SVG per graph into --svg-dir and replaces, in --readme, the text
between each `<!-- generated: NAME -->` line and the next
`<!-- /generated -->` line with block NAME; every other line of the README
stays exactly as it was. The output depends on the raw files alone, so a
second run writes the same bytes. Python 3 standard library only."""
import argparse
import re
import statistics
import sys
from collections import OrderedDict, defaultdict
from math import floor, log10
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# label -> (name in tables and graphs, series: kajo | interpreter | jit | native)
RUNTIMES = OrderedDict([
    ("kajo", ("Kajo (kasm)", "kajo")),
    ("kajo-st", ("Kajo (Smalltalk)", "kajo")),
    ("pharo", ("Pharo 12 (Cog JIT)", "jit")),
    ("c", ("C (clang -O2)", "native")),
    ("luajit", ("LuaJIT", "jit")),
    ("luajit-joff", ("LuaJIT -joff", "interpreter")),
    ("lua", ("Lua 5.4", "interpreter")),
    ("node", ("Node (V8)", "jit")),
    ("node-jitless", ("Node --jitless", "interpreter")),
    ("java", ("Java (G1)", "jit")),
    ("java-int", ("Java -Xint", "interpreter")),
    ("java-zgc", ("Java (ZGC)", "jit")),
    ("ruby", ("Ruby", "interpreter")),
    ("ruby-yjit", ("Ruby --yjit", "jit")),
    ("python", ("CPython", "interpreter")),
])
SERIES = OrderedDict([
    ("kajo", ("Kajo (no JIT)", "#2563eb")),
    ("interpreter", ("interpreter, JIT off", "#d97706")),
    ("jit", ("JIT", "#7c3aed")),
    ("native", ("native code", "#059669")),
])
KERNELS = ["fib", "dispatch", "binarytrees", "collections", "arith"]
# What one run does, for the derived rates; the parameters are the
# programs' (experiments/runtime-comparison/RESULTS.md).
FIB_REPS, DISPATCH_REPS, TREE_REPS, ARITH_TOTAL = 960, 100_000_000, 1280, 320_000_000
P = 1_000_000_007


def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a


FIB_CALLS = (FIB_REPS // 2) * ((2 * fib(28) - 1) + (2 * fib(29) - 1))
TREE_NODES = TREE_REPS * (2 ** 17 - 1) + (2 ** 13 - 1)
ARITH_SUBTRACTS = (3 * ARITH_TOTAL * (ARITH_TOTAL - 1) // 2 + 7 * ARITH_TOTAL - 684800000) // P
# Kajo's arith.kasm: 21 bytecodes per iteration, 4 more when it subtracts.
ARITH_BYTECODES = 21 * ARITH_TOTAL + 4 * ARITH_SUBTRACTS
WORK = {
    "fib": (FIB_CALLS, "M calls/s"),
    "dispatch": (DISPATCH_REPS, "M sends/s"),
    "binarytrees": (TREE_NODES, "M objects/s"),
    "arith": (ARITH_TOTAL, "M iterations/s"),
}


# --- reading ---------------------------------------------------------------

def parse_line(raw):
    d = {}
    for tok in raw.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            d.setdefault(k, v)
    return d


def read_raw(path):
    header, versions, runs = OrderedDict(), OrderedDict(), []
    for raw in path.read_text().splitlines():
        if raw.startswith("#"):
            body = raw[1:].strip()
            if body.startswith("version "):
                name, _, v = body[len("version "):].partition(":")
                versions[name.strip()] = v.strip()
            elif ":" in body:
                k, _, v = body.partition(":")
                header[k.strip()] = v.strip()
            continue
        if raw.strip():
            runs.append(parse_line(raw))
    return header, versions, runs


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def stats(xs):
    xs = sorted(xs)
    return {"median": statistics.median(xs), "min": xs[0], "max": xs[-1], "n": len(xs)}


class Data:
    def __init__(self, runs):
        self.runs = runs
        self.ok = [r for r in runs if r.get("ok") == "yes" and r.get("round") != "repeat"]
        self.refused = [r for r in runs if r.get("ok") != "yes"]
        self.repeats = [r for r in runs if r.get("ok") == "yes" and r.get("round") == "repeat"]
        self.groups = defaultdict(list)
        for r in self.ok:
            self.groups[(r["kernel"], r["runtime"], int(r["workers"]))].append(r)

    def rows(self, kernel, workers=None):
        out = []
        for (k, rt, w), rs in self.groups.items():
            if k == kernel and (workers is None or w == workers):
                out.append((rt, w, stats([float(r["ms"]) for r in rs]), rs))
        order = list(RUNTIMES)
        out.sort(key=lambda x: (x[1], x[2]["median"], order.index(x[0]) if x[0] in order else 99))
        return out

    def median(self, kernel, runtime, workers=1, key="ms"):
        rs = self.groups.get((kernel, runtime, workers), [])
        xs = [num(r.get(key)) for r in rs]
        xs = [x for x in xs if x is not None]
        return statistics.median(xs) if xs else None


def name(rt, workers=1):
    n = RUNTIMES.get(rt, (rt, "jit"))[0]
    return n if workers == 1 else f"{n}, {workers} workers (aggregate)"


def series(rt):
    return RUNTIMES.get(rt, (rt, "jit"))[1]


# --- formatting ------------------------------------------------------------

def secs(ms):
    s = ms / 1000
    if s >= 10:
        return f"{s:.1f}"
    if s >= 1:
        return f"{s:.2f}"
    return f"{s:.3f}"


def spread(st):
    return 100 * (st["max"] - st["min"]) / st["median"]


def kernel_table(d, kernel, ref="kajo"):
    rows = d.rows(kernel)
    if not rows:
        return "_No runs._\n"
    if not d.median(kernel, ref):
        ref = "kajo-st"
    refms = d.median(kernel, ref)
    work = WORK.get(kernel)
    head = f"| runtime | median s | min–max s | spread | time against {name(ref)} |"
    sep = "|---|--:|--:|--:|--:|"
    if work:
        head += f" {work[1]} |"
        sep += "--:|"
    out = [head, sep]
    for rt, w, st, rs in rows:
        rel = f"{st['median'] / refms:.2f}×" if refms else "-"
        line = (f"| {'**' + name(rt, w) + '**' if series(rt) == 'kajo' else name(rt, w)} | {secs(st['median'])} | "
                f"{secs(st['min'])}–{secs(st['max'])} | {spread(st):.1f}% | {rel} |")
        if work:
            line += f" {work[0] / (st['median'] / 1000) / 1e6:.1f} |"
        out.append(line)
    return "\n".join(out) + "\n"


# --- SVG -------------------------------------------------------------------

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def nice_ticks_linear(hi):
    step = 10 ** floor(log10(hi)) if hi > 0 else 1
    for m in (1, 2, 5, 10):
        if hi / (step * m) <= 6:
            step *= m
            break
    ticks, t = [], 0.0
    while t <= hi * 1.0001:
        ticks.append(t)
        t += step
    if ticks[-1] < hi:
        ticks.append(ticks[-1] + step)
    return ticks


def fmt_tick(v):
    if v == 0:
        return "0"
    if v >= 1:
        return f"{v:g}"
    return f"{v:g}"


def bar_svg(title, bars, unit_label, value_fmt, log=None, max_line=None):
    """bars: [(label, value, series)]; values > 0."""
    left, right, top, row = 200, 90, 58, 24
    width = 760
    plot = width - left - right
    height = top + row * len(bars) + 44
    vals = [v for _, v, _ in bars]
    lo, hi = min(vals), max(vals + ([max_line] if max_line else []))
    if log is None:
        log = hi / lo > 20
    if log:
        a, b = floor(log10(lo)), floor(log10(hi)) + 1
        if log10(lo) - a < 0.3:  # a bar at the axis's first decade would not show
            a -= 1
        if 10 ** (b - 1) >= hi:
            b -= 1
        ticks = [10.0 ** e for e in range(a, b + 1)]

        def x(v):
            return left + plot * (log10(v) - a) / (b - a)
    else:
        ticks = nice_ticks_linear(hi)
        top_v = ticks[-1]

        def x(v):
            return left + plot * v / top_v
    o = []
    o.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" '
             f'font-family="-apple-system, BlinkMacSystemFont, \'Segoe UI\', Helvetica, Arial, sans-serif" font-size="12" '
             f'role="img" aria-label="{esc(title)}">')
    o.append(f"<title>{esc(title)}</title>")
    o.append(f'<g fill="currentColor"><text x="{left}" y="18" font-size="14" font-weight="600">{esc(title)}</text></g>')
    # legend: only the series present
    lx = left
    present = [s for s in SERIES if any(b[2] == s for b in bars)]
    for s in present:
        text, color = SERIES[s]
        if s == "kajo":
            o.append(f'<rect x="{lx}" y="28" width="12" height="12" fill="{color}"/>')
        else:
            o.append(f'<rect x="{lx + 0.75}" y="28.75" width="10.5" height="10.5" fill="{color}" fill-opacity="0.18" stroke="{color}" stroke-width="1.5"/>')
        o.append(f'<text x="{lx + 17}" y="38.5" fill="currentColor">{esc(text)}</text>')
        lx += 30 + 6.6 * len(text)
    # grid and axis
    base = top + row * len(bars)
    o.append('<g stroke="currentColor" stroke-opacity="0.18">')
    for t in ticks:
        o.append(f'<line x1="{x(t):.1f}" y1="{top - 6}" x2="{x(t):.1f}" y2="{base}"/>')
    o.append("</g>")
    o.append(f'<line x1="{left}" y1="{base}" x2="{left + plot}" y2="{base}" stroke="currentColor" stroke-opacity="0.6"/>')
    o.append('<g fill="currentColor" fill-opacity="0.8" text-anchor="middle">')
    for t in ticks:
        o.append(f'<text x="{x(t):.1f}" y="{base + 16}">{fmt_tick(t)}</text>')
    o.append("</g>")
    o.append(f'<text x="{left + plot / 2:.1f}" y="{base + 34}" fill="currentColor" text-anchor="middle">{esc(unit_label + (", log scale (each gridline 10×)" if log else ""))}</text>')
    if max_line:
        o.append(f'<line x1="{x(max_line):.1f}" y1="{top - 6}" x2="{x(max_line):.1f}" y2="{base}" stroke="currentColor" stroke-opacity="0.6"/>')
    # bars
    for i, (label, v, s) in enumerate(bars):
        y = top + row * i
        color = SERIES[s][1]
        x0 = x(ticks[0]) if log else left
        w = max(x(v) - x0, 1.5)
        o.append(f'<text x="{left - 8}" y="{y + 15.5}" fill="currentColor" text-anchor="end"{" font-weight=\"600\"" if s == "kajo" else ""}>{esc(label)}</text>')
        if s == "kajo":
            o.append(f'<rect x="{x0:.1f}" y="{y + 4}" width="{w:.1f}" height="{row - 8}" fill="{color}"/>')
        else:
            o.append(f'<rect x="{x0 + 0.75:.1f}" y="{y + 4.75}" width="{max(w - 1.5, 0.5):.1f}" height="{row - 9.5}" fill="{color}" fill-opacity="0.18" stroke="{color}" stroke-width="1.5"/>')
        o.append(f'<text x="{x0 + w + 6:.1f}" y="{y + 15.5}" fill="currentColor">{esc(value_fmt(v))}</text>')
    o.append("</svg>")
    return "\n".join(o) + "\n"


def kernel_svg(d, kernel, title):
    rows = d.rows(kernel, workers=1)
    if not rows:
        return None
    bars = [(name(rt), st["median"] / 1000, series(rt)) for rt, w, st, rs in rows]
    return bar_svg(title, bars, "seconds per run, median of the rounds (shorter is faster)", lambda v: f"{secs(v * 1000)} s")


# --- blocks ----------------------------------------------------------------

def block_meta(header, data):
    return (f"Measured {header.get('date', '-')} at commit `{header.get('commit', '-')}` on {header.get('machine', '-')}, "
            f"macOS {header.get('macos', '-')}; {header.get('rounds', '-')} interleaved rounds, every run bounded at "
            f"{header.get('timeout', '-')}; the time is the process's wall time.\n")


def img(file, alt):
    return f"![{alt}]({file})\n"


def block_sends(d, svgs):
    out = []
    for k, title in (("fib", "fib: recursive Fibonacci"), ("dispatch", "dispatch: one polymorphic send site")):
        svg = kernel_svg(d, k, title)
        out.append(f"**{k}** ({'960 × fib(27 or 28), ' + format(FIB_CALLS, ',') + ' calls' if k == 'fib' else format(DISPATCH_REPS, ',') + ' sends over three classes plus an indexed read'} per run)\n")
        if svg:
            svgs[f"{k}.svg"] = svg
            out.append(img(f"{k}.svg", title))
        out.append(kernel_table(d, k))
    return "\n".join(out)


def pause_table(d):
    rows = d.rows("binarytrees")
    out = ["| runtime | collections per run | pause p50 ms | pause p99 ms | pause max ms | Kajo's own young collections p50 / p99 ms |",
           "|---|--:|--:|--:|--:|--:|"]
    any_row = False
    for rt, w, st, rs in rows:
        def m(key, fmt="{:.3f}"):
            xs = [num(r.get(key)) for r in rs]
            xs = [x for x in xs if x is not None]
            return fmt.format(statistics.median(xs)) if xs else "-"
        if rt in ("kajo", "kajo-st"):
            out.append(f"| {name(rt, w)} | {m('young', '{:.0f}')} young, {m('stops', '{:.0f}')} stops | {m('pause_p50')} | {m('pause_p99')} | {m('pause_max')} | {m('young_p50')} / {m('young_p99')} |")
            any_row = True
        elif rt.startswith("java"):
            out.append(f"| {name(rt, w)} | {m('pauses', '{:.0f}')} pauses | {m('pause_p50')} | {m('pause_p99')} | {m('pause_max')} | - |")
            any_row = True
        elif rt == "pharo":
            sc, scms, fu, fums = (m("scavenges", "{:.0f}"), num(m("scavenge_ms", "{:.0f}")), m("full", "{:.0f}"), m("full_ms", "{:.0f}"))
            mean = f"{scms / float(sc):.3f} (mean)" if scms is not None and num(sc) else "-"
            out.append(f"| {name(rt, w)} | {sc} scavenges, {fu} full ({fums} ms) | {mean} | - | - | - |")
            any_row = True
    return ("\n".join(out) + "\n") if any_row else ""


def block_allocation(d, svgs):
    out = [f"**binarytrees** (one long-lived tree of depth 12, then {TREE_REPS} trees of depth 16 built, checked and dropped: {TREE_NODES:,} objects per run)\n"]
    svg = kernel_svg(d, "binarytrees", "binarytrees: allocation and collection")
    if svg:
        svgs["binarytrees.svg"] = svg
        out.append(img("binarytrees.svg", "binarytrees"))
    out.append(kernel_table(d, "binarytrees"))
    pt = pause_table(d)
    if pt:
        out.append("Collector pauses where the runtime reports them (medians over the rounds of each run's own percentiles; "
                   "Kajo's pauses are its stops, its young collections on one worker run on the program's own thread; "
                   "the JVM's from `-Xlog:gc`; Pharo reports only counts and totals):\n")
        out.append(pt)
    return "\n".join(out)


def block_bytecodes(d, svgs):
    out = [f"**arith** ({ARITH_TOTAL:,} iterations of `sum := sum + (i * 3 + 7)`, a conditional subtract of 1000000007; "
           f"in Kajo's kasm {ARITH_BYTECODES:,} bytecodes per run)\n"]
    svg = kernel_svg(d, "arith", "arith: the special arithmetic bytecodes")
    if svg:
        svgs["arith.svg"] = svg
        out.append(img("arith.svg", "arith"))
    out.append(kernel_table(d, "arith"))
    km = d.median("arith", "kajo")
    kn = d.median("arith", "kajo", key="kernel_ms")
    if km and kn:
        out.append(f"Kajo (kasm) runs {ARITH_BYTECODES / (kn / 1000) / 1e6:.0f} M bytecodes/s in its own kernel time "
                   f"({secs(kn)} s of the {secs(km)} s process).\n")
    return "\n".join(out)


def block_library(d, svgs):
    out = ["**collections** (three times: an OrderedCollection of a million SmallIntegers filled and summed with `do:` "
           "and `inject:into:`; a Dictionary of 200 000 Symbol keys built and looked up; a String of a million characters "
           "built with a WriteStream and scanned; 500 000 SmallIntegers sorted; the same source in both)\n"]
    svg = kernel_svg(d, "collections", "collections: the Smalltalk library")
    if svg:
        svgs["collections.svg"] = svg
        out.append(img("collections.svg", "collections"))
    out.append(kernel_table(d, "collections", ref="kajo-st"))
    return "\n".join(out)


def block_scaling(d, svgs):
    out = ["| runtime | kernel | 1 worker s | 8 workers s | speedup |", "|---|---|--:|--:|--:|"]
    bars = []
    for k in KERNELS:
        for rt in ("kajo", "kajo-st"):
            one, eight = d.median(k, rt, 1), d.median(k, rt, 8)
            if one and eight:
                out.append(f"| {name(rt)} | {k} | {secs(one)} | {secs(eight)} | {one / eight:.2f}× |")
                bars.append((f"{name(rt)} {k}", one / eight, "kajo"))
    if not bars:
        return "_No 8-worker runs._\n"
    svgs["scaling.svg"] = bar_svg("Kajo: 8 workers against 1 (the same total work)", bars,
                                  "speedup, process wall time (the line is 8×)", lambda v: f"{v:.2f}×", log=False, max_line=8)
    return img("scaling.svg", "scaling") + "\n" + "\n".join(out) + "\n"


def block_slices(path):
    if not path or not path.exists():
        return "_No raw file of `just bench`._\n"
    head, rows = [], defaultdict(list)
    order = []
    for raw in path.read_text().splitlines():
        if raw.startswith("#"):
            head.append(raw[1:].strip())
            continue
        r = parse_line(raw)
        if "variant" not in r:
            continue
        key = (r["kernel"], r["variant"])
        if key not in order:
            order.append(key)
        rows[(r["kernel"], r["variant"], int(r["workers"]))].append(float(r["ms"]))
    out = []
    if head:
        out.append("From " + "; ".join(head) + ".\n")
    out.append("| kernel | variant | 1 worker ms | 8 workers ms | speedup |")
    out.append("|---|---|--:|--:|--:|")
    for k, v in order:
        one, eight = rows.get((k, v, 1)), rows.get((k, v, 8))
        m1 = statistics.median(one) if one else None
        m8 = statistics.median(eight) if eight else None
        sp = f"{m1 / m8:.2f}×" if m1 and m8 else "-"
        out.append(f"| {k} | {v} | {f'{m1:.1f}' if m1 else '-'} | {f'{m8:.1f}' if m8 else '-'} | {sp} |")
    return "\n".join(out) + "\n"


def block_devices(dirs):
    rows = []
    for dd in dirs:
        f = Path(dd) / "scenarios.txt"
        if not f.exists():
            continue
        g = defaultdict(list)
        for raw in f.read_text().splitlines():
            r = parse_line(raw)
            if "scenario" in r:
                g[(r.get("scenario"), r.get("young", "-"))].append(r)
        for (s, y), rs in g.items():
            def m(key):
                xs = [num(r.get(key)) for r in rs]
                xs = [x for x in xs if x is not None]
                return f"{statistics.median(xs):.0f}" if xs else "-"
            th = ",".join(sorted({r.get("thermal_end", "-") for r in rs}))
            rows.append(f"| {Path(dd).name} | {s} | {y} | {m('missed')} of {m('expected')} | {m('main_stopped_others_ms_per10s')} | {len(rs)} | {th} |")
    if not rows:
        return ""
    return "\n".join(["| device rows | scenario | young | frames missed of expected | main stopped for others ms/10 s | launches | thermal at end |",
                      "|---|---|---|--:|--:|--:|---|"] + rows) + "\n"


def block_caveats(header, d):
    out = []
    missing = header.get("missing", "-")
    out.append(f"- Runtimes missing from this run: {missing if missing not in ('', '-') else 'none'}.")
    th = defaultdict(int)
    for r in d.runs:
        th[r.get("thermal", "-")] += 1
    out.append("- Thermal state at the runs' starts: " + ", ".join(f"{k} {v}" for k, v in sorted(th.items())) + " runs.")
    if d.refused:
        ref = "; ".join(f"{r.get('runtime')} {r.get('kernel')} w{r.get('workers')} round {r.get('round')} ({r.get('reason')}, checksum {r.get('checksum')})" for r in d.refused)
        out.append(f"- Refused runs ({len(d.refused)}, not in any number above): {ref}.")
    else:
        out.append("- Refused runs: none; every run printed its kernel's checksum.")
    sp = []
    for (k, rt, w), rs in sorted(d.groups.items()):
        st = stats([float(r["ms"]) for r in rs])
        sp.append((spread(st), k, rt, w, st["n"]))
    if sp:
        wide = [s for s in sp if s[0] > 5]
        mx = max(sp)
        out.append(f"- Spread of the medians ((max − min) / median over each row's {mx[4]} rounds): at most {mx[0]:.1f}% "
                   f"({name(mx[2], mx[3])}, {mx[1]}); "
                   + (f"{len(wide)} of {len(sp)} rows above 5%: " + ", ".join(f"{name(rt, w)} {k} {s:.1f}%" for s, k, rt, w, n in sorted(wide, reverse=True)) + "."
                      if wide else f"all {len(sp)} rows within 5%."))
    rep = []
    for r in d.repeats:
        m = d.median(r["kernel"], r["runtime"], int(r["workers"]))
        if m:
            rep.append((float(r["ms"]) / m, r))
    if rep:
        lo, hi = min(rep, key=lambda x: x[0]), max(rep, key=lambda x: x[0])
        out.append(f"- Drift: the first kernel ({rep[0][1]['kernel']}) run again at the end took {lo[0]:.3f} to {hi[0]:.3f} times its median "
                   f"({name(lo[1]['runtime'], int(lo[1]['workers']))} to {name(hi[1]['runtime'], int(hi[1]['workers']))}).")
    out.append("- Every time is the whole process's wall time, start-up included for every runtime alike "
               "(Kajo loads its image or assembles its kasm, the JVM and Pharo start their VMs); "
               "a run of a few hundred milliseconds is mostly start-up.")
    return "\n".join(out) + "\n"


def block_versions(header, versions, raw_path, slices_path):
    out = ["| runtime | version |", "|---|---|"]
    for k, v in versions.items():
        out.append(f"| {name(k)} | {v} |")
    out.append("")
    out.append(f"Raw files: `{raw_path}` ({header.get('rounds', '-')} rounds) and `{slices_path}`.")
    return "\n".join(out) + "\n"


# --- README ----------------------------------------------------------------

MARK = re.compile(r"(<!-- generated: ([A-Za-z0-9_-]+) -->\n)(.*?)(<!-- /generated -->)", re.S)


def fill(readme_text, blocks):
    seen = set()

    def rep(m):
        n = m.group(2)
        if n not in blocks:
            return m.group(0)
        seen.add(n)
        body = blocks[n]
        if body and not body.endswith("\n"):
            body += "\n"
        return m.group(1) + body + m.group(4)
    text = MARK.sub(rep, readme_text)
    return text, set(blocks) - seen


def rel(path):
    try:
        return str(Path(path).resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--raw", default=str(ROOT / "experiments/runtime-comparison/bench-raw.txt"))
    ap.add_argument("--slices", default=str(ROOT / "experiments/runtime-comparison/slices-raw.txt"))
    ap.add_argument("--device", action="append", default=[])
    ap.add_argument("--readme", default=str(ROOT / "docs/performance/README.md"))
    ap.add_argument("--svg-dir", default=None)
    a = ap.parse_args()
    raw = Path(a.raw)
    if not raw.exists():
        sys.exit(f"perf-report: no raw file {raw}")
    header, versions, runs = read_raw(raw)
    d = Data(runs)
    svgs = OrderedDict()
    blocks = OrderedDict()
    blocks["meta"] = block_meta(header, d)
    blocks["sends"] = block_sends(d, svgs)
    blocks["allocation"] = block_allocation(d, svgs)
    blocks["bytecodes"] = block_bytecodes(d, svgs)
    blocks["library"] = block_library(d, svgs)
    blocks["scaling"] = block_scaling(d, svgs)
    blocks["slices"] = block_slices(Path(a.slices))
    blocks["devices"] = block_devices(a.device)
    blocks["caveats"] = block_caveats(header, d)
    blocks["versions"] = block_versions(header, versions, rel(a.raw), rel(a.slices))
    readme = Path(a.readme)
    text, missing = fill(readme.read_text(), blocks)
    if missing:
        sys.exit(f"perf-report: {readme} has no marker for: {', '.join(sorted(missing))}")
    svg_dir = Path(a.svg_dir) if a.svg_dir else readme.parent
    svg_dir.mkdir(parents=True, exist_ok=True)
    for f, s in svgs.items():
        (svg_dir / f).write_text(s)
    readme.write_text(text)
    print(f"perf-report: {readme} ({len(blocks)} blocks), {len(svgs)} SVGs in {svg_dir}")


main()
