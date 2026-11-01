#!/usr/bin/env python3
"""Tables for RESULTS.md from bench.sh's raw files: kernels, pauses, scenarios."""
import sys, os, statistics as st, collections

KRAW, SRAW, PRAW = sys.argv[1:4]
KERNELS = ['arith', 'fib', 'sends', 'ivars', 'alloc', 'churn', 'survivors5', 'survivors30']
CFGS = ['nobar', 'bar0', 'g1', 'g4', 'g16']

def kv(line):
    d = {}
    for t in line.split():
        if '=' in t:
            k, v = t.split('=', 1)
            d.setdefault(k, v)  # first occurrence wins (tag before payload)
    return d

def parse(path):
    rows = []
    if not os.path.exists(path): return rows
    for line in open(path):
        if line.startswith('#'):
            print(line.strip()); continue
        if line.strip(): rows.append(kv(line))
    return rows

def fl(r, k, d=None):
    try: return float(r[k])
    except (KeyError, ValueError): return d

def med(xs):
    xs = [x for x in xs if x is not None]
    return st.median(xs) if xs else None

def pct(xs, p):
    if not xs: return None
    s = sorted(xs)
    return s[min(len(s) - 1, int(round((len(s) - 1) * p)))]

def f(x, d=1):
    return '-' if x is None else f"{x:.{d}f}"

krows = parse(KRAW)
prows = parse(PRAW)

# pooled pauses: (cfg, build, kernel, workers) -> list of rows
pools = collections.defaultdict(list)
for p in prows:
    if 'kernel' in p:
        pools[(p['cfg'], p['build'], p['kernel'], int(p['workers']))].append(p)
    elif 'scenario' in p:
        pools[('scenario', 'O', p['scenario'], 0)].append(p)

def pauses(key, kind='scav', field='total'):
    return [int(p[field]) / 1e6 for p in pools.get(key, []) if p['kind'] == kind]

grp = collections.defaultdict(list)
for r in krows:
    if 'kernel' in r: grp[(r['cfg'], r['build'], r['kernel'], int(r['workers']))].append(r)

def ok(rs): return [r for r in rs if 'FAILED' not in r]
def mfield(key, field): return med([fl(r, field) for r in ok(grp.get(key, []))])
def fails(key): return sum(1 for r in grp.get(key, []) if 'FAILED' in r)

if grp:
    print("\n## 1. Headless matrix (O build; medians of runs; pauses pooled over runs, ms)\n")
    print("| kernel | workers | config | wall ms | vs nobar | scavenges | pause p50 | p99 | max | promoted MB | survival % | remset mean | entry sweep p50 | max | fulls | full max | checksum |")
    print("|---|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|")
    for k in KERNELS:
        for n in (1, 8):
            base = mfield(('nobar', 'O', k, n), 'ms')
            sums = {r['checksum'] for c in CFGS for b in ('O', 'align32') for r in ok(grp.get((c, b, k, n), []))}
            for c in CFGS:
                key = (c, 'O', k, n)
                if key not in grp: continue
                nf = fails(key)
                if not ok(grp[key]):
                    print(f"| {k} | {n} | {c} | FAILED ({nf}/{len(grp[key])} runs: out of memory) | | | | | | | | | | | | | |"); continue
                ms = mfield(key, 'ms')
                sc = pauses(key)
                es = pauses(key, field='sweep')
                fu = pauses(key, 'full')
                print(f"| {k} | {n} | {c} | {f(ms)} | {f(ms / base, 2) if base else '-'} | {f(mfield(key, 'scavenges'), 0)} | "
                      f"{f(pct(sc, .5), 3)} | {f(pct(sc, .99), 3)} | {f(max(sc) if sc else None, 3)} | "
                      f"{f(mfield(key, 'promoted_mb'), 1)} | {f(mfield(key, 'survival_pct'), 1)} | {f(mfield(key, 'remset_mean'), 0)} | "
                      f"{f(pct(es, .5), 3)} | {f(max(es) if es else None, 3)} | {f(mfield(key, 'fulls'), 0)} | {f(max(fu) if fu else None, 2)} | "
                      f"{sorted(sums)[0] if sums else '-'}{'' if len(sums) <= 1 else ' MISMATCH'}{' (' + str(nf) + ' failed)' if nf else ''} |")
    extra = ('nobar512', 'O', 'survivors5', 8)
    if extra in grp:
        key = extra
        fu = pauses(key, 'full')
        print(f"\nsurvivors5, 8 workers, nobar with a 512 MiB old space: wall {f(mfield(key, 'ms'))} ms, "
              f"{f(mfield(key, 'fulls'), 0)} full collections, full p50/max {f(pct(fu, .5), 2)} / {f(max(fu) if fu else None, 2)} ms, "
              f"old space at exit {f(mfield(key, 'old_mb'), 1)} MiB, failed runs {fails(key)}")

    print("\n## 2. Barrier cost (median wall ms; bar0 = barrier compiled in, never fires; g4 = generational 4 MiB)\n")
    print("| kernel | workers | build | nobar | bar0 | bar0/nobar | g4 | g4/nobar | barrier slow-path calls (g4) |")
    print("|---|--:|---|--:|--:|--:|--:|--:|--:|")
    for k in KERNELS:
        for n in (1, 8):
            for b in ('O', 'align32'):
                a = mfield(('nobar', b, k, n), 'ms'); z = mfield(('bar0', b, k, n), 'ms'); g = mfield(('g4', b, k, n), 'ms')
                if a is None and z is None: 
                    if ('nobar', b, k, n) in grp: print(f"| {k} | {n} | {b} | FAILED | FAILED | - | {f(g)} | - | {f(mfield(('g4', b, k, n), 'barrier_slow'), 0)} |")
                    continue
                print(f"| {k} | {n} | {b} | {f(a)} | {f(z)} | {f(z / a, 3) if a and z else '-'} | {f(g)} | {f(g / a, 3) if a and g else '-'} | {f(mfield(('g4', b, k, n), 'barrier_slow'), 0)} |")

    print("\n## 4. Entry churn (O build, medians of runs)\n")
    print("| kernel | workers | config | entries alloc / scavenge | freed / scavenge | entry sweep p50 / max ms | sweep share % | table hwm (entries) | fresh chunks | bits per word taken | word takes |")
    print("|---|--:|---|--:|--:|---|--:|--:|--:|--:|--:|")
    for k in ['alloc', 'churn', 'survivors5', 'survivors30']:
        for n in (1, 8):
            for c in ['nobar', 'g1', 'g4', 'g16']:
                key = (c, 'O', k, n)
                if not ok(grp.get(key, [])): continue
                es = pauses(key, field='sweep')
                print(f"| {k} | {n} | {c} | {f(mfield(key, 'ent_alloc_per_scav'), 0)} | {f(mfield(key, 'ent_freed_per_scav'), 0)} | "
                      f"{f(pct(es, .5), 3)} / {f(max(es) if es else None, 3)} | {f(mfield(key, 'share_sweep'), 1)} | {f(mfield(key, 'table_hwm'), 0)} | "
                      f"{f(mfield(key, 'chunk_fresh'), 0)} | {f(mfield(key, 'bits_per_word'), 1)} | {f(mfield(key, 'word_takes'), 0)} |")

def breakdown(key):
    rs = [p for p in pools.get(key, []) if p['kind'] == 'scav']
    if not rs: return None
    tot = sum(int(p['total']) for p in rs)
    sh = lambda fld: 100 * sum(int(p[fld]) for p in rs) / tot
    m = lambda fld: st.median(int(p[fld]) / 1e6 for p in rs)
    return rs, sh, m

scal = [k for k in grp if k[0] == 'scale']
if scal:
    print("\n## 3. Pause scaling, g4, O build (pauses pooled over runs; breakdown = share of total scavenge pause time)\n")
    print("| kernel | workers | scavenges | pause p50 | p99 | max | participants | promoted KiB / scavenge | coord % | roots % | remset % | copy % | entry sweep % | ttsp p50 ms | mean busy / pause |")
    print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
    for k in ['alloc', 'churn', 'survivors30']:
        for n in (1, 2, 4, 8):
            key = ('scale', 'O', k, n)
            b = breakdown(key)
            if not b: continue
            rs, sh, m = b
            sc = [int(p['total']) / 1e6 for p in rs]
            prom = st.mean(int(p['promoted']) for p in rs) / 1024
            busy = st.median(int(p['busy']) / max(int(p['total']), 1) for p in rs)
            print(f"| {k} | {n} | {len(rs)} | {f(pct(sc, .5), 3)} | {f(pct(sc, .99), 3)} | {f(max(sc), 3)} | "
                  f"{f(st.mean(int(p['parts']) for p in rs), 1)} | {f(prom, 0)} | {f(sh('coord'))} | {f(sh('roots'))} | {f(sh('rem'))} | "
                  f"{f(sh('copy'))} | {f(sh('sweep'))} | {f(m('ttsp'), 3)} | {f(busy, 2)} |")

srows = parse(SRAW)
sg = collections.defaultdict(list)
for r in srows: sg[r['scenario']].append(r)
def median_run(rs):
    rs = sorted(rs, key=lambda r: (fl(r, 'missed', 0), fl(r, 'gap_max_ms', 0)))
    return rs[(len(rs) - 1) // 2]
if sg:
    print("\n## 5. Scenarios: median run of", max(len(v) for v in sg.values()), "(by missed frames, then max gap); pauses of the median run, ms\n")
    print("| id | Hz | frames | drops | missed | gap max | worst run-loop iter (VM, GC park, GC enter wait) | scavenges | pause p50 / p99 / max | fulls | full p50 / max | ttsp p50 / p99 / max | main enter waits (max) | ev lat p50 / p99 / max | survival % | per-run missed |")
    print("|---|--:|--:|--:|--:|--:|---|--:|---|--:|---|---|---|---|--:|---|")
    for sc in ['G0', 'G1', 'G2', 'G3', 'G4', 'G5']:
        if sc not in sg: continue
        r = median_run(sg[sc])
        g = lambda k: r.get(k, '-')
        per = ", ".join(str(int(fl(x, 'missed', 0))) for x in sorted(sg[sc], key=lambda x: int(x['run'])))
        print(f"| {sc} | {g('refresh_hz')} | {g('frames')} | {g('drops')} | {g('missed')} | {g('gap_max_ms')} | "
              f"{g('worst_iter_ms')} ({g('worst_iter_vm_ms')}, {g('worst_iter_gcpark_ms')}, {g('worst_iter_gcenter_ms')}) | {g('scavenges')} | "
              f"{g('pause_p50')} / {g('pause_p99')} / {g('pause_max')} | {g('fulls')} | {g('full_p50')} / {g('full_max')} | "
              f"{g('ttsp_p50')} / {g('ttsp_p99')} / {g('ttsp_max')} | {g('main_enter_waits')} ({g('main_enter_wait_max_ms')}) | "
              f"{g('ev_lat_p50_ms')} / {g('ev_lat_p99_ms')} / {g('ev_lat_max_ms')} | {g('survival_pct')} | {per} |")
    print("\n## 5b. Scenario pauses pooled over all runs (ms)\n")
    print("| id | scavenges | pause p50 | p99 | max | scavenges > 4 ms | ttsp p50 | p99 | max | fulls | full p50 | max | coord % | copy % | remset % | sweep % |")
    print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
    for sc in ['G1', 'G2', 'G3', 'G4', 'G5']:
        key = ('scenario', 'O', sc, 0)
        s = pauses(key); t = pauses(key, field='ttsp'); fu = pauses(key, 'full')
        b = breakdown(key)
        shs = (f(b[1]('coord')), f(b[1]('copy')), f(b[1]('rem')), f(b[1]('sweep'))) if b else ('-',) * 4
        print(f"| {sc} | {len(s)} | {f(pct(s, .5), 3)} | {f(pct(s, .99), 3)} | {f(max(s) if s else None, 3)} | {sum(1 for x in s if x > 4)} | "
              f"{f(pct(t, .5), 3)} | {f(pct(t, .99), 3)} | {f(max(t) if t else None, 3)} | {len(fu)} | {f(pct(fu, .5), 2)} | {f(max(fu) if fu else None, 2)} | "
              f"{shs[0]} | {shs[1]} | {shs[2]} | {shs[3]} |")
    print("\n## Scenario extras (median runs)\n")
    for sc in ['G0', 'G1', 'G2', 'G3', 'G4', 'G5']:
        if sc not in sg: continue
        r = median_run(sg[sc])
        keys = ['turns', 'vm_main_ms', 'max_turn_ms', 'max_turn_kind', 'max_turn_gcpark_ms', 'max_turn_gcenter_ms', 'events_posted', 'events_handled',
                'ev_post_lat_p50_ms', 'ev_post_lat_p99_ms', 'timer_late_p99_ms', 'churn100us', 'promoted_mb', 'remset_mean', 'brk_coord', 'brk_copy',
                'brk_rem', 'brk_sweep', 'parts_mean', 'esweep_p50', 'esweep_max', 'old_mb', 'rss_mb']
        print(f"- **{sc}**: " + ", ".join(f"{x}={r[x]}" for x in keys if x in r))
