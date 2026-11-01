#!/usr/bin/env python3
"""Tables for RESULTS.md from bench.sh's raw files: kernels, pauses and cycles, scenarios."""
import sys, os, gzip, statistics as st, collections

KRAW, SRAW, PRAW = sys.argv[1:4]
KERNELS = ['arith', 'fib', 'sends', 'ivars', 'alloc', 'churn', 'survivors5', 'survivors30',
           'oldheap64', 'oldheap256', 'oldheap512']
CFGS = ['nomark', 'stw', 'cm', 'cm2', 'force']
COMPUTE = ['arith', 'fib', 'sends', 'ivars', 'churn']


def kv(line):
    d = {}
    for t in line.split():
        if '=' in t:
            k, v = t.split('=', 1)
            d.setdefault(k, v)  # first occurrence wins (tag before payload)
    return d


def parse(path):
    """Reads `path`, or `path.gz` if only that exists (the committed dump)."""
    rows = []
    if not os.path.exists(path):
        if not os.path.exists(path + '.gz'):
            return rows
        f = gzip.open(path + '.gz', 'rt')
    else:
        f = open(path)
    for line in f:
        if line.startswith('#'):
            print(line.strip())
            continue
        if line.strip():
            rows.append(kv(line))
    return rows


def fl(r, k, d=None):
    try:
        return float(r[k])
    except (KeyError, ValueError):
        return d


def med(xs):
    xs = [x for x in xs if x is not None]
    return st.median(xs) if xs else None


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    return s[min(len(s) - 1, int(round((len(s) - 1) * p)))]


def f(x, d=1):
    return '-' if x is None else f"{x:.{d}f}"


def dist(xs, d=3):
    if not xs:
        return '- / - / -'
    return f"{f(pct(xs, .5), d)} / {f(pct(xs, .99), d)} / {f(max(xs), d)}"


krows = parse(KRAW)
prows = parse(PRAW)
srows = parse(SRAW)

# pooled pauses and cycles: (cfg, build, kernel-or-scenario, workers) -> rows
pools = collections.defaultdict(list)
for p in prows:
    if 'kernel' in p:
        pools[(p['cfg'], p['build'], p['kernel'], int(p['workers']))].append(p)
    elif 'scenario' in p:
        pools[('scenario', 'O', p['scenario'], 0)].append(p)


def recs(key, kind):
    return [p for p in pools.get(key, []) if p['kind'] == kind]


def ms(rows, field):
    return [int(p[field]) / 1e6 for p in rows]


grp = collections.defaultdict(list)
for r in krows:
    if 'kernel' in r:
        grp[(r['cfg'], r['build'], r['kernel'], int(r['workers']))].append(r)


def ok(rs):
    return [r for r in rs if 'FAILED' not in r]


def mfield(key, field):
    return med([fl(r, field) for r in ok(grp.get(key, []))])


def fails(key):
    return sum(1 for r in grp.get(key, []) if 'FAILED' in r)


def total(key, field):
    xs = [fl(r, field, 0) for r in ok(grp.get(key, []))]
    return int(sum(xs)) if xs else None


if grp:
    print("\n## 1. Headless matrix (O build; wall, RSS: medians of runs; pauses pooled over runs, ms)\n")
    print("| kernel | workers | config | wall ms | vs stw | peak RSS MB | scavenge p50 / p99 / max | full collections | full p50 / max | cycles | fallbacks (all runs) | checksum |")
    print("|---|--:|---|--:|--:|--:|---|--:|---|--:|--:|---|")
    for k in KERNELS:
        for n in (1, 8):
            base = mfield(('stw', 'O', k, n), 'ms')
            sums = {r['checksum'] for c in CFGS for b in ('O', 'align32') for r in ok(grp.get((c, b, k, n), []))}
            for c in CFGS:
                key = (c, 'O', k, n)
                if key not in grp:
                    continue
                nf = fails(key)
                if nf == len(grp[key]):
                    print(f"| {k} | {n} | {c} | FAILED ({nf}/{nf} runs) | | | | | | | | |")
                    continue
                w = mfield(key, 'ms')
                rel = f(w / base, 2) if base and w else '-'
                sc = ms(recs(key, 'scav') + recs(key, 'initial'), 'total')
                fu = ms(recs(key, 'full') + recs(key, 'fallback'), 'total')
                nfull = med([fl(r, 'fulls', 0) for r in ok(grp[key])])
                cyc = med([fl(r, 'cycles', 0) for r in ok(grp[key])]) if c not in ('nomark', 'stw') else None
                fb = total(key, 'fallbacks') if c not in ('nomark', 'stw') else None
                fullcol = f"{f(pct(fu, .5), 2)} / {f(max(fu), 2)}" if fu else '-'
                cs = r['checksum'] if (r := ok(grp[key])[0]) else '-'
                note = '' if len(sums) == 1 else ' (MISMATCH)'
                failed = f" ({nf} failed)" if nf else ''
                print(f"| {k} | {n} | {c} | {f(w)}{failed} | {rel} | {f(mfield(key, 'rss_mb'), 0)} | {dist(sc)} | {f(nfull, 0)} | {fullcol} | "
                      f"{f(cyc, 0)} | {'-' if fb is None else fb} | {cs}{note} |")

    print("\n## 1b. Concurrent pauses and cycles (O build; pauses and cycles pooled over runs; ms)\n")
    print("| kernel | workers | config | cycles (all runs) | initial p50 / p99 / max | of which mark p50 / max | final p50 / p99 / max | final ttsp p50 | final drain max | marking p50 / max | marker CPU p50 | SATB entries / cycle p50 | fallbacks |")
    print("|---|--:|---|--:|---|---|---|--:|--:|---|--:|--:|--:|")
    for k in KERNELS:
        for n in (1, 8):
            for c in ('cm', 'cm2', 'force'):
                key = (c, 'O', k, n)
                if key not in grp:
                    continue
                ini = recs(key, 'initial')
                fin = recs(key, 'final')
                cyc = [p for p in recs(key, 'cycle') if p['done'] == '1' and p['aborted'] == '0']
                allc = recs(key, 'cycle')
                if not allc:
                    print(f"| {k} | {n} | {c} | 0 | | | | | | | | | {total(key, 'fallbacks')} |")
                    continue
                mk = [(int(p['snap']) + int(p['cmroots'])) / 1e6 for p in ini]
                fin_t = [(int(p['total']) - int(p['verify'])) / 1e6 for p in fin]
                mdur = ms(cyc, 'marking')
                print(f"| {k} | {n} | {c} | {len(allc)} | {dist(ms(ini, 'total'))} | {f(pct(mk, .5), 3)} / {f(max(mk) if mk else None, 3)} | "
                      f"{dist(fin_t)} | {f(pct(ms(fin, 'ttsp'), .5), 3)} | {f(max(ms(fin, 'drain')) if fin else None, 3)} | "
                      f"{f(pct(mdur, .5), 1)} / {f(max(mdur) if mdur else None, 1)} | {f(pct(ms(cyc, 'markcpu'), .5), 1)} | "
                      f"{f(pct([int(p['satb']) for p in cyc], .5), 0)} | {total(key, 'fallbacks')} |")

    print("\n## 2. Barrier cost (medians of runs, ms)\n")
    print("`stw/nomark`: the SATB fast path compiled in, marking never on. `force/stw`: marking flag on all the time and cycles back to back.\n")
    print("| kernel | workers | build | nomark | stw | stw/nomark | force | force/stw | SATB slow-path calls (force) |")
    print("|---|--:|---|--:|--:|--:|--:|--:|--:|")
    for k in KERNELS:
        for n in (1, 8):
            for b in ('O', 'align32'):
                a, s = mfield(('nomark', b, k, n), 'ms'), mfield(('stw', b, k, n), 'ms')
                if a is None and s is None:
                    continue
                fo = mfield(('force', 'O', k, n), 'ms') if b == 'O' else None
                slow = mfield(('force', 'O', k, n), 'satb_slow') if b == 'O' else None
                print(f"| {k} | {n} | {b} | {f(a)} | {f(s)} | {f(s / a, 3) if a and s else '-'} | {f(fo)} | "
                      f"{f(fo / s, 3) if fo and s else '-'} | {f(slow, 0)} |")

    print("\n## 3. Pause breakdown and scaling with old-space size (oldheap; pooled over runs; ms)\n")
    print("| kernel | workers | config | stw full p50 / max | initial p50 / max | scavenge part p50 | snapshot p50 / max | root scan p50 / max | root words p50 | final p50 / p99 / max | final ttsp p50 / max | drain p50 / max | drained entries max | apply p50 / max |")
    print("|---|--:|---|---|---|--:|---|---|--:|---|---|---|--:|---|")
    for k in ('oldheap64', 'oldheap256', 'oldheap512'):
        for n in (1, 8):
            for c in ('stw', 'cm', 'cm2'):
                key = (c, 'O', k, n)
                if key not in grp:
                    continue
                fu = ms(recs(key, 'full') + recs(key, 'fallback'), 'total')
                ini, fin = recs(key, 'initial'), recs(key, 'final')
                ap = [int(p['apply']) / 1e6 for p in pools.get(key, []) if p['kind'] != 'cycle' and int(p.get('apply', 0)) > 0]
                def pm(xs, d=3):
                    return f"{f(pct(xs, .5), d)} / {f(max(xs) if xs else None, d)}"
                print(f"| {k} | {n} | {c} | {pm(fu, 2) if fu else '-'} | {pm(ms(ini, 'total'))} | {f(pct(ms(ini, 'scavpart'), .5), 3)} | "
                      f"{pm(ms(ini, 'snap'))} | {pm(ms(ini, 'cmroots'))} | {f(pct([int(p['rootwords']) for p in ini], .5), 0)} | "
                      f"{dist([(int(p['total']) - int(p['verify'])) / 1e6 for p in fin])} | {pm(ms(fin, 'ttsp'))} | {pm(ms(fin, 'drain'))} | "
                      f"{max([int(p['drainent']) for p in fin]) if fin else '-'} | {pm(ap)} |")

    print("\n## 4. Marker throughput, promotion rate, headroom (cycles pooled over runs)\n")
    print("Promotion rate: promoted MB over wall time (median run). Headroom: old space at the final mark minus at the initial mark.\n")
    print("| kernel | workers | config | promotion MB/s | cycles done / aborted | marked MB p50 | marking ms p50 / max | marker CPU ms p50 | marker MB per CPU s | sweep CPU ms p50 | sweep to apply ms p50 | promoted during marking MB p50 / max | old at start MB p50 | headroom used MB p50 / max | freed MB p50 | fallbacks |")
    print("|---|--:|---|--:|---|--:|---|--:|--:|--:|--:|---|--:|---|--:|--:|")
    for k in ['alloc', 'churn', 'survivors5', 'survivors30', 'oldheap64', 'oldheap256', 'oldheap512']:
        for n in (1, 8):
            for c in ('cm', 'cm2'):
                key = (c, 'O', k, n)
                if key not in grp:
                    continue
                allc = recs(key, 'cycle')
                done = [p for p in allc if p['done'] == '1' and p['aborted'] == '0']
                app = [p for p in done if p['applied'] == '1']
                ab = sum(1 for p in allc if p['aborted'] == '1')
                prom = med([fl(r, 'promoted_mb', 0) / (fl(r, 'ms', 1) / 1000) for r in ok(grp[key])])
                mb = [int(p['marked']) / 1048576 for p in done]
                cpu = sum(int(p['markcpu']) for p in done) / 1e9
                thr = sum(mb) / cpu if cpu > 0 else None
                pr = [int(p['promoted']) / 1048576 for p in done]
                head = [(int(p['oldfinal']) - int(p['oldstart'])) * 32768 / 1048576 for p in done]
                print(f"| {k} | {n} | {c} | {f(prom, 0)} | {len(done)} / {ab} | {f(pct(mb, .5), 1)} | "
                      f"{f(pct(ms(done, 'marking'), .5), 1)} / {f(max(ms(done, 'marking')) if done else None, 1)} | "
                      f"{f(pct(ms(done, 'markcpu'), .5), 1)} | {f(thr, 0)} | {f(pct(ms(app, 'sweepcpu'), .5), 2)} | "
                      f"{f(pct(ms(app, 'toapply'), .5), 1)} | {f(pct(pr, .5), 1)} / {f(max(pr) if pr else None, 1)} | "
                      f"{f(pct([int(p['oldstart']) * 32768 / 1048576 for p in done], .5), 1)} | "
                      f"{f(pct(head, .5), 1)} / {f(max(head) if head else None, 1)} | "
                      f"{f(pct([int(p['freed']) / 1048576 for p in app], .5), 1)} | {total(key, 'fallbacks')} |")

    extras = sorted({c for (c, b, k, n) in grp if c.startswith('cm-') or c.startswith('stw-')})
    if extras:
        print("\n## 4b. Threshold and marker QoS (8 workers, cm; medians of runs, fallbacks summed)\n")
        print("`-h256`: 256 MiB old space instead of 64. `qoshigh`: marker at QoS user-initiated instead of utility.\n")
        print("| kernel | config | wall ms | cycles | fallbacks (all runs) | stw fulls (median) | full or fallback pause max | final max | marking ms p50 | marker CPU ms p50 |")
        print("|---|---|--:|--:|--:|--:|--:|--:|--:|--:|")
        for k in ('alloc', 'survivors30', 'oldheap256'):
            for c in ['cm'] + extras:
                key = (c, 'O', k, 8)
                if key not in grp:
                    continue
                fu = ms(recs(key, 'fallback') + recs(key, 'full'), 'total')
                done = [p for p in recs(key, 'cycle') if p['done'] == '1' and p['aborted'] == '0']
                fin = recs(key, 'final')
                print(f"| {k} | {c} | {f(mfield(key, 'ms'))} | {f(mfield(key, 'cycles'), 0)} | {total(key, 'fallbacks')} | {f(mfield(key, 'fulls'), 0)} | "
                      f"{f(max(fu) if fu else None, 2)} | {f(max(ms(fin, 'total')) if fin else None, 3)} | "
                      f"{f(pct(ms(done, 'marking'), .5), 1)} | {f(pct(ms(done, 'markcpu'), .5), 1)} |")

    print("\n## 4c. oldheap mutation rates and live size (medians of runs)\n")
    print("| kernel | workers | config | build ms | mutate ms | rewires/s | replaced MB/s | live MB (sweep) |")
    print("|---|--:|---|--:|--:|--:|--:|--:|")
    for k in ('oldheap64', 'oldheap256', 'oldheap512'):
        for n in (1, 8):
            for c in ('stw', 'cm'):
                key = (c, 'O', k, n)
                if key not in grp:
                    continue
                print(f"| {k} | {n} | {c} | {f(mfield(key, 'build_ms'))} | {f(mfield(key, 'mutate_ms'))} | "
                      f"{f(mfield(key, 'rewires_per_s'), 0)} | {f(mfield(key, 'replaced_mb_per_s'))} | {f(mfield(key, 'live_mb_p50'))} |")

# ---- scenarios
if srows:
    by = collections.defaultdict(list)
    ver = []
    for r in srows:
        if 'scenario' not in r:
            continue
        (ver if r.get('verify') == '1' else by[r['scenario']]).append(r)
    print("\n## 5. Scenarios (median run of 3 by missed frames, then max gap; pauses of the median run, ms)\n")
    print("| id | gc | frames | missed | gap max | worst run-loop iter (VM, GC park, GC enter/leave wait) | scavenges | scav p50 / p99 / max | full / fallback | full max | cycles | initial p50 / max | final p50 / max | marking ms p50 | per-run missed |")
    print("|---|---|--:|--:|--:|---|--:|---|---|--:|--:|---|---|--:|---|")
    meds = {}
    for sc in sorted(by):
        rs = sorted(by[sc], key=lambda r: (int(r['missed']), float(r['gap_max_ms'])))
        m = rs[len(rs) // 2]
        meds[sc] = m
        per = ', '.join(r['missed'] for r in sorted(by[sc], key=lambda r: int(r['run'])))
        fulls = int(m.get('fulls', 0))
        fb = int(m.get('fallback_pauses', 0))
        print(f"| {sc} | {m.get('gc')} | {m['frames']} | {m['missed']} | {m['gap_max_ms']} | "
              f"{m['worst_iter_ms']} ({m['worst_iter_vm_ms']}, {m['worst_iter_gcpark_ms']}, {m['worst_iter_gcenter_ms']}) | "
              f"{m.get('scavenges', 0)} | {m.get('pause_p50', '-')} / {m.get('pause_p99', '-')} / {m.get('pause_max', '-')} | "
              f"{fulls - fb} / {fb} | {m.get('full_max', '-')} | {m.get('cycles', '-')} | "
              f"{m.get('initial_p50', '-')} / {m.get('initial_max', '-')} | {m.get('final_p50', '-')} / {m.get('final_max', '-')} | "
              f"{m.get('marking_ms_p50', '-')} | {per} |")
    print("\nPauses pooled over all three runs, ms:\n")
    print("| id | scavenges | scav p50 / p99 / max | initial (incl. scavenge) p50 / p99 / max | final p50 / p99 / max | stw full p50 / max | fallback p50 / max | ttsp p99 / max | pauses > 4 ms | world stopped % (per run) |")
    print("|---|--:|---|---|---|---|---|---|--:|---|")
    for sc in sorted(by):
        key = ('scenario', 'O', sc, 0)
        sca = ms(recs(key, 'scav'), 'total')
        ini = ms(recs(key, 'initial'), 'total')
        fin = ms(recs(key, 'final'), 'total')
        fu = ms(recs(key, 'full'), 'total')
        fb = ms(recs(key, 'fallback'), 'total')
        allp = [p for p in pools.get(key, []) if p['kind'] != 'cycle']
        tt = ms(allp, 'ttsp')
        over = sum(1 for x in ms(allp, 'total') if x > 4)
        stopped = []
        for run in sorted({p['run'] for p in allp}):
            tot = sum(int(p['total']) for p in allp if p['run'] == run)
            stopped.append(f(100 * tot / 10e9, 1))
        def pm(xs):
            return f"{f(pct(xs, .5), 2)} / {f(max(xs), 2)}" if xs else '-'
        print(f"| {sc} | {len(sca) + len(ini)} | {dist(sca)} | {dist(ini)} | {dist(fin)} | {pm(fu)} | {pm(fb)} | "
              f"{f(pct(tt, .99), 3)} / {f(max(tt) if tt else None, 3)} | {over} | {', '.join(stopped)} |")
    print("\nScenario extras (median runs):\n")
    keys = ['build_wait_s', 'turns', 'vm_main_ms', 'max_turn_ms', 'max_turn_kind', 'max_turn_gcpark_ms', 'max_turn_gcenter_ms',
            'ev_lat_p50_ms', 'ev_lat_p99_ms', 'ev_lat_max_ms', 'main_enter_waits', 'main_enter_wait_max_ms', 'churn100us',
            'promoted_mb', 'survival_pct', 'markers', 'marker_qos', 'mark_cpu_ms_total', 'sweep_cpu_ms_total', 'marked_mb_p50',
            'promoted_during_mb_max', 'old_start_mb_p50', 'old_after_mb_p50', 'satb_entries', 'old_mb', 'rss_mb']
    for sc in sorted(meds):
        m = meds[sc]
        print(f"- **{sc}**: " + ', '.join(f"{k}={m[k]}" for k in keys if k in m))
    if ver:
        print("\nVerifier runs (mark sets compared with a from-scratch traversal at every final mark; one run each):\n")
        print("| id | missed frames | cycles | verifier runs | missed objects | floating garbage MB max | final p50 / max without verifier | verifier max ms | fallbacks |")
        print("|---|--:|--:|--:|--:|--:|---|--:|--:|")
        for r in ver:
            print(f"| {r['scenario']} | {r['missed']} | {r.get('cycles')} | {r.get('cm_verify_runs', '0')} | {r.get('cm_missed', '-')} | "
                  f"{r.get('floating_mb_max')} | {r.get('final_p50')} / {r.get('final_max')} | {r.get('final_verify_max')} | {r.get('fallback_pauses')} |")
