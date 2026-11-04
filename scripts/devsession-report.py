#!/usr/bin/env python3
"""Module 9c: the tables of docs/modules/developer-ui.md's Measurements from
`just mac-shell run <out> mode=devsession ...` result lines (one file or
several): the scripted sessions' frames, steps and request round trips, and
the typing measurement. Medians over the runs, the range in brackets."""
import json, re, statistics, sys

def fields(line):
    out = {}
    for m in re.finditer(r'(\w+)=(\{.*\}$|\S+)', line):
        out[m.group(1)] = m.group(2)
    return out

def med(xs):
    xs = sorted(xs)
    if not xs:
        return "-"
    m = statistics.median(xs)
    return f"{m:.1f}" if len(xs) == 1 or xs[0] == xs[-1] else f"{m:.1f} [{xs[0]:.1f}–{xs[-1]:.1f}]"

runs = []
for path in sys.argv[1:]:
    for line in open(path):
        if "mode=devsession" in line and "run=" in line:
            runs.append(fields(line.strip()))

sessions = [r for r in runs if r.get("typing", "0") == "0" and "session" in r]
typing = [r for r in runs if r.get("typing", "0") != "0"]

if sessions:
    by = {}
    for r in sessions:
        by.setdefault((r["classes"], r["load"]), []).append(r)
    print("| classes | load | runs | seconds | frames (of expected) | missed | max gap ms | longest turn ms | footprint MB |")
    print("|--:|---|--:|--:|--:|--:|--:|--:|--:|")
    for (c, l), rs in sorted(by.items()):
        print(f"| {c} | {l} | {len(rs)} | {med([float(r['seconds']) for r in rs])} | "
              f"{med([float(r['frames']) for r in rs])} ({med([float(r['expected']) for r in rs])}) | "
              f"{med([float(r['missed']) for r in rs])} | {med([float(r['gap_max_ms']) for r in rs])} | "
              f"{med([float(r['max_turn_ms']) for r in rs])} | {med([float(r['footprint_peak_mb']) for r in rs])} |")
    for (c, l), rs in sorted(by.items()):
        print(f"\nSteps, classes={c} load={l} (ms, frames missed in the step):\n")
        print("| step | ms | missed |")
        print("|---|--:|--:|")
        steps = {}
        order = []
        for r in rs:
            for part in r.get("steps_ms_missed", "").split(","):
                if not part:
                    continue
                name, ms, missed = part.rsplit(":", 2)
                # a step that runs twice in a session (step) is numbered
                seen = sum(1 for o in order if o.split("#")[0] == name)
                key = name
                n = [p.rsplit(":", 2)[0] for p in r.get("steps_ms_missed", "").split(",")][: r.get("steps_ms_missed", "").split(",").index(part) + 1].count(name)
                if n > 1:
                    key = f"{name}#{n}"
                steps.setdefault(key, []).append((float(ms), float(missed)))
                if key not in order:
                    order.append(key)
        for name in order:
            v = steps[name]
            print(f"| {name} | {med([a for a, _ in v])} | {med([b for _, b in v])} |")
        print(f"\nRequest round trips, classes={c} load={l} (ms; count per run, p50, p99, max):\n")
        print("| request | count | p50 | p99 | max |")
        print("|---|--:|--:|--:|--:|")
        kinds = {}
        for r in rs:
            s = json.loads(r["session"])
            for k, v in s.get("requests", {}).items():
                kinds.setdefault(k, []).append(v)
        for k in sorted(kinds):
            v = kinds[k]
            print(f"| `{k}` | {med([x[0] for x in v])} | {med([x[1] / 1000 for x in v])} | {med([x[2] / 1000 for x in v])} | {med([x[3] / 1000 for x in v])} |")

if typing:
    print("\n| classes | load | runs | keys | key to redraw p50 ms | p99 ms | max ms | key to colours p50 ms | p99 ms | frames missed while typing (of) |")
    print("|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|")
    by = {}
    for r in typing:
        by.setdefault((r["classes"], r["load"]), []).append(r)
    for (c, l), rs in sorted(by.items()):
        print(f"| {c} | {l} | {len(rs)} | {med([float(r['type_n']) for r in rs])} | {med([float(r['type_p50_ms']) for r in rs])} | "
              f"{med([float(r['type_p99_ms']) for r in rs])} | {med([float(r['type_max_ms']) for r in rs])} | "
              f"{med([float(r['colour_p50_ms']) for r in rs])} | {med([float(r['colour_p99_ms']) for r in rs])} | "
              f"{med([float(r.get('typing_missed', 'nan')) for r in rs])} ({med([float(r.get('typing_frames', 'nan')) for r in rs])}) |")
