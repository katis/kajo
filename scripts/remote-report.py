#!/usr/bin/env python3
"""Module 9d: the tables of docs/modules/phone-transport.md's Measurements
from scripts/remote-session.sh's files (and 9c's local session lines for the
comparison): request round trips by kind and target form, the session's
steps, the dropped link, and the serving target's frames with and without a
client. Medians over the runs, the range in brackets.

    python3 scripts/remote-report.py <outdir>...  (every client-*.txt,
    serve-*.txt and local*.txt in them)"""
import glob, json, os, re, statistics, sys

def fields(line):
    out = {}
    for m in re.finditer(r'(\w+)=(\{.*\}(?= thermal=)|\S+)', line):
        out.setdefault(m.group(1), m.group(2))
    return out

def med(xs, f="{:.1f}"):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return "-"
    m = statistics.median(xs)
    s = f.format(m)
    return s if xs[0] == xs[-1] else f"{s} [{f.format(xs[0])}–{f.format(xs[-1])}]"

def group(tag):
    # tags are <form>-<run> or <form>-<run>-<session>; local-<run>
    return re.sub(r'-\d+(-\d+)?$', '', tag)

clients, serves = [], []
for d in sys.argv[1:]:
    for p in sorted(glob.glob(os.path.join(d, "*.txt"))):
        for line in open(p):
            if "mode=devsession" in line and " run=" in line and "session=" in line:
                r = fields(line.strip())
                r["_group"] = group(r.get("tag", "-"))
                clients.append(r)
            elif "mode=scenario" in line and " run=" in line and "frames=" in line:
                r = fields(line.strip())
                r["_group"] = group(r.get("tag", "-"))
                serves.append(r)

def session(r):
    s = r["session"].replace("_", " ")
    try:
        return json.loads(r["session"].replace("_", " "))
    except Exception:
        return json.loads(r["session"])

groups = sorted({r["_group"] for r in clients})
print("## Sessions\n")
print("| target | sessions | failed | seconds | missed | reconnects | outage ms | retried |")
print("|---|--:|--:|--:|--:|--:|--:|--:|")
for g in groups:
    rs = [r for r in clients if r["_group"] == g]
    ss = [session(r) for r in rs]
    out = [o[0] / 1000 for s in ss for o in s.get("outages", [])]
    print(f"| {g} | {len(rs)} | {sum(1 for s in ss if s.get('failure'))} | {med([float(r['seconds']) for r in rs])} | "
          f"{med([float(r['missed']) for r in rs])} | {med([s.get('reconnects', 0) for s in ss])} | {med(out)} | "
          f"{med([s.get('retried', 0) for s in ss])} |")

kinds = sorted({k for r in clients for k in session(r).get("requests", {})})
print("\n## Round trips (ms: p50 of each session's p50, and the max of the maxima)\n")
print("| request | " + " | ".join(f"{g} n | {g} p50 | {g} max" for g in groups) + " |")
print("|---|" + "--:|--:|--:|" * len(groups))
for k in kinds:
    cells = []
    for g in groups:
        v = [session(r)["requests"][k] for r in clients if r["_group"] == g and k in session(r).get("requests", {})]
        if not v:
            cells += ["-", "-", "-"]
            continue
        cells += [med([x[0] for x in v], "{:.0f}"), med([x[1] / 1000 for x in v]), f"{max(x[3] for x in v) / 1000:.1f}"]
    print(f"| `{k}` | " + " | ".join(cells) + " |")

steps = []
for r in clients:
    for part in r.get("steps_ms_missed", "").split(","):
        if part:
            n = part.rsplit(":", 2)[0]
            if n not in steps:
                steps.append(n)
print("\n## Steps (ms, frames missed by the client shell in the step)\n")
print("| step | " + " | ".join(f"{g} ms | missed" for g in groups) + " |")
print("|---|" + "--:|--:|" * len(groups))
for st in steps:
    cells = []
    for g in groups:
        ms, mi = [], []
        for r in clients:
            if r["_group"] != g:
                continue
            seen = [p.rsplit(":", 2) for p in r.get("steps_ms_missed", "").split(",") if p]
            for name, a, b in seen:
                if name == st:
                    ms.append(float(a)); mi.append(float(b))
                    break
        cells += [med(ms), med(mi, "{:.0f}")]
    print(f"| {st} | " + " | ".join(cells) + " |")

if serves:
    print("\n## The serving target's frames\n")
    print("| row | runs | scenario | missed (of expected) | max gap ms | longest turn ms | served requests | served KB | deliver max µs | writer max KB | thermal start→end |")
    print("|---|--:|---|--:|--:|--:|--:|--:|--:|--:|---|")
    for g in sorted({r["_group"] for r in serves}):
        rs = [r for r in serves if r["_group"] == g]
        th = ",".join(f"{r.get('thermal_start','-')}→{r.get('thermal_end','-')}" for r in rs)
        def num(r, k):
            v = r.get(k)
            try:
                return float(v)
            except (TypeError, ValueError):
                return None
        print(f"| {g} | {len(rs)} | {rs[0].get('scenario')} | {med([num(r,'missed') for r in rs], '{:.0f}')} ({med([num(r,'expected') for r in rs], '{:.0f}')}) | "
              f"{med([num(r,'gap_max_ms') for r in rs])} | {med([num(r,'max_turn_ms') for r in rs])} | "
              f"{med([num(r,'served_requests') for r in rs], '{:.0f}')} | {med([(num(r,'served_bytes') or 0) / 1024 for r in rs], '{:.0f}')} | "
              f"{med([num(r,'deliver_max_us') for r in rs])} | {med([num(r,'writer_max_pending_kb') for r in rs])} | {th} |")
