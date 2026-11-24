#!/usr/bin/env python3
"""The weekly margins (docs/modules/weekly-margins.md): the margins the tests
print, read from a directory of gate outputs (a weekly run's, a module's
check/), as Markdown tables.

    scripts/margins.py <dir> [--previous <dir>]

A test that waits against a bound prints one line when the wait ends,
passing or failing (the helper in each test target, `Margins.swift`):

    kajo-margin name=<name> kind=<kind> value=<v> bound=<b> unit=<unit>

kind is deadline (a clock on the whole wait), quiet (the longest stretch
with no progress against a quiet bound), ceiling (a measured value an
assertion bounds) or time (a value with no bound: bound=-). The first
table has one row per name: per gate the value over the bound and the
fraction, the largest fraction, the previous run's largest with
--previous, and THIN when the fraction is 0.8 or more in any gate (PAST
at 1 or more). Rows with a fraction come first, largest first; then the
times. The second table is each gate's own time against its bound
(gates.log: the start line's bound=, the end line's seconds).

Under the tables: lines that start with `kajo-margin` and do not parse
(UNKNOWN: counted and quoted, never a row), names printed more than once
in a gate (the largest fraction is used, the count said), names present
in one of the four whole-suite gates and absent from another that has
output, names the previous run had and this one has not, gates whose
output is not here, and files that could not be read.

The gate outputs read are the gates whose command is `swift test` (the
whole suite: swift-test, swift-test-load, tsan, tsan-load; parts of it:
test-release, soak, compiler-tests), and any other *.txt that holds a
margin line (named as a gate this reader does not know). Exit status 0
whatever it finds, 2 on a usage error. Python's standard library only."""
import os
import re
import sys

THIN = 0.8
WHOLE = ["swift-test", "swift-test-load", "tsan", "tsan-load"]
GATES = WHOLE + ["test-release", "soak", "compiler-tests"]
KINDS = {"deadline", "quiet", "ceiling", "time"}
FIELDS = ["name", "kind", "value", "bound", "unit"]
PREFIX = "kajo-margin"
NAME = re.compile(r"^[A-Za-z0-9._:/#+-]+$")


def usage(msg):
    print(f"margins: {msg}\nusage: scripts/margins.py <dir> [--previous <dir>]", file=sys.stderr)
    sys.exit(2)


def parse(line):
    """A margin line's fields, or None when it does not parse: every field
    once, in order, a known kind, numbers where numbers belong, `-` as the
    bound of a time and only of a time."""
    toks = line.split()
    if not toks or toks[0] != PREFIX or len(toks) != 1 + len(FIELDS):
        return None
    kv = {}
    for want, tok in zip(FIELDS, toks[1:]):
        k, sep, v = tok.partition("=")
        if not sep or k != want or not v:
            return None
        kv[k] = v
    if kv["kind"] not in KINDS or not NAME.match(kv["name"]):
        return None
    try:
        kv["value"] = float(kv["value"])
        if kv["kind"] == "time":
            if kv["bound"] != "-":
                return None
            kv["bound"] = None
        else:
            kv["bound"] = float(kv["bound"])
            if kv["bound"] <= 0:
                return None
    except ValueError:
        return None
    if kv["value"] != kv["value"]:  # NaN (a negative value is a value: a CPU overrun under its budget)
        return None
    return kv


def fraction(m):
    return None if m["bound"] is None else m["value"] / m["bound"]


def read_run(d):
    """{gate: {name: (margin, count)}}, unknown lines, gates not known, files
    unreadable."""
    gates, unknown, strangers, unreadable = {}, [], [], []
    try:
        names = sorted(os.listdir(d))
    except OSError as e:
        return gates, unknown, strangers, [f"{d}: {e.strerror}"]
    for f in names:
        if not f.endswith(".txt"):
            continue
        g = f[:-4]
        path = os.path.join(d, f)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError as e:
            unreadable.append(f"{f}: {e.strerror}")
            continue
        found = {}
        any_margin = False
        for n, line in enumerate(lines, 1):
            s = line.strip()
            if PREFIX not in s:
                continue
            if not s.startswith(PREFIX + " ") and s != PREFIX:
                # The prefix inside another line (an expectation's message
                # quoting it, two writes run together): not a margin.
                unknown.append((g, n, s))
                continue
            any_margin = True
            m = parse(s)
            if m is None:
                unknown.append((g, n, s))
                continue
            old = found.get(m["name"])
            if old is None:
                found[m["name"]] = (m, 1)
            else:
                keep = old[0]
                fo, fn = fraction(old[0]), fraction(m)
                if (fn if fn is not None else -1) > (fo if fo is not None else -1) or (fn is None and fo is None and m["value"] > old[0]["value"]):
                    keep = m
                found[m["name"]] = (keep, old[1] + 1)
        if g in GATES:
            gates[g] = found
        elif any_margin:
            gates[g] = found
            strangers.append(g)
    return gates, unknown, strangers, unreadable


def read_gates_log(d):
    """[(gate, rc, seconds, bound or None)] from gates.log, the last run of
    each gate; or None without one."""
    path = os.path.join(d, "gates.log")
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    bound, ends, order = {}, {}, []
    for line in lines:
        t = line.split()
        if len(t) < 5:
            continue
        what, g = t[3], t[4].rstrip(":")
        if what == "start":
            m = re.search(r" bound=(\d+)s$", line)
            bound[g] = int(m.group(1)) if m else None
        elif what == "end" and not g.startswith("fuzz-") and len(t) >= 7:
            rc = t[5][3:] if t[5].startswith("rc=") else t[5]
            sec = t[6][:-1] if t[6].endswith("s") else t[6]
            ends[g] = (rc, sec, bound.get(g))
            if g not in order:
                order.append(g)
    return [(g,) + ends[g] for g in order]


def num(x):
    if x >= 100:
        return f"{x:.0f}"
    if x >= 1:
        return f"{x:.1f}"
    return f"{x:.3f}"


def cell(entry):
    if entry is None:
        return "-"
    m, count = entry
    more = f" x{count}" if count > 1 else ""
    if m["bound"] is None:
        return f"{num(m['value'])}{more}"
    return f"{num(m['value'])}/{num(m['bound'])} ({fraction(m):.2f}){more}"


def largest(gates, name):
    fs = [fraction(g[name][0]) for g in gates.values() if name in g and fraction(g[name][0]) is not None]
    return max(fs) if fs else None


def main(argv):
    args, prev = [], None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--previous":
            if i + 1 >= len(argv):
                usage("--previous needs a directory")
            prev = argv[i + 1]
            i += 2
            continue
        if a.startswith("-"):
            usage(f"unknown option {a}")
        args.append(a)
        i += 1
    if len(args) != 1:
        usage("one directory")
    d = args[0]
    if not os.path.isdir(d):
        usage(f"{d} is not a directory")

    gates, unknown, strangers, unreadable = read_run(d)
    pgates = None
    if prev is not None:
        pgates, _, _, punread = read_run(prev)
        if punread:
            unreadable += [f"previous {u}" for u in punread]
    order = [g for g in GATES if g in gates] + sorted(strangers)
    names = sorted({n for g in gates.values() for n in g})

    print(f"### Margins the tests printed ({os.path.basename(os.path.normpath(d))})\n")
    print(f"Gates read: {', '.join(order) if order else 'none'}. A cell is value/bound (fraction) in the row's unit; "
          f"xN: printed N times, the largest fraction kept. THIN: {THIN} or more in any gate; PAST: 1 or more.\n")
    if names:
        head = ["margin", "kind", "unit"] + order + ["largest"] + (["previous"] if prev is not None else []) + ["mark"]
        print("| " + " | ".join(head) + " |")
        print("|" + "|".join(["---"] * 3 + ["--:"] * (len(order) + 1 + (1 if prev is not None else 0)) + ["---"]) + "|")

        def key(n):
            f = largest(gates, n)
            vmax = max(g[n][0]["value"] for g in gates.values() if n in g)
            return (0, -f, n) if f is not None else (1, -vmax, n)
        for n in sorted(names, key=key):
            ms = [g[n][0] for g in gates.values() if n in g]
            kinds = "/".join(sorted({m["kind"] for m in ms}))
            units = "/".join(sorted({m["unit"] for m in ms}))
            f = largest(gates, n)
            row = [n, kinds, units] + [cell(gates[g].get(n)) for g in order]
            row.append(f"{f:.2f}" if f is not None else "-")
            if prev is not None:
                pf = largest(pgates, n) if pgates and any(n in g for g in pgates.values()) else None
                row.append(f"{pf:.2f}" if pf is not None else ("new" if not any(n in g for g in (pgates or {}).values()) else "-"))
            row.append("PAST" if f is not None and f >= 1 else ("THIN" if f is not None and f >= THIN else ""))
            print("| " + " | ".join(row) + " |")
    else:
        print("No margin lines in the gates read.")

    log = read_gates_log(d)
    print("\n### The gates' own times against their bounds (gates.log)\n")
    if log is None:
        print("No gates.log here.")
    elif not log:
        print("No gate ended in gates.log.")
    else:
        print("| gate | rc | seconds | bound | fraction | mark |")
        print("|---|---|--:|--:|--:|---|")
        for g, rc, sec, b in log:
            try:
                s = float(sec)
            except ValueError:
                s = None
            f = s / b if (s is not None and b) else None
            mark = "PAST" if f is not None and f >= 1 else ("THIN" if f is not None and f >= THIN else "")
            print(f"| {g} | {rc} | {sec} | {b if b else '- (not logged)'} | {f'{f:.2f}' if f is not None else '-'} | {mark} |")

    notes = []
    if unknown:
        notes.append(f"UNKNOWN: {len(unknown)} line(s) with `{PREFIX}` that do not parse (not rows, not passes):")
        notes += [f"  - {g}.txt:{n}: `{s[:200]}`" for g, n, s in unknown]
    dup = [(g, n, c) for g in order for n, (m, c) in sorted(gates[g].items()) if c > 1]
    if dup:
        notes.append("Printed more than once in a gate (the largest fraction kept): "
                     + ", ".join(f"{n} in {g} x{c}" for g, n, c in dup))
    ran = [g for g in WHOLE if g in gates]
    absent = []
    for n in names:
        if any(n in gates[g] for g in ran):
            miss = [g for g in ran if n not in gates[g]]
            if miss:
                absent.append(f"{n} (not in {', '.join(miss)})")
    if absent:
        notes.append("Absent from a whole-suite gate that has output: " + "; ".join(absent))
    if pgates is not None:
        gone = sorted({n for g in pgates.values() for n in g} - set(names))
        if gone:
            notes.append("Gone since the previous run: " + ", ".join(gone))
    if strangers:
        notes.append("Gates this reader does not know (read as gates): " + ", ".join(f"{g}.txt" for g in strangers))
    missing = [g for g in GATES if g not in gates]
    if missing:
        notes.append("No output here for: " + ", ".join(missing))
    if unreadable:
        notes.append("Could not read: " + "; ".join(unreadable))
    if notes:
        print()
        for x in notes:
            print(x if x.startswith("  ") else f"- {x}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
