#!/usr/bin/env python3
"""Tables for RESULTS.md from bench.sh's raw files: kernels, pauses and cycles, scenarios."""
import sys, os, gzip, statistics as st, collections

KRAW, SRAW, PRAW = sys.argv[1:4]
KERNELS = ['arith', 'fib', 'sends', 'ivars', 'storeheavy', 'alloc', 'churn', 'survivors5', 'survivors30',
           'oldheap64', 'oldheap256', 'oldheap512', 'fragment']
CFGS = ['stw', 'adr6', 'n2', 'n4', 'r25', 'r50', 'r75', 'ragg', 'nops']
RELOC = ['r25', 'r50', 'r75', 'ragg']
COMPUTE = ['arith', 'fib', 'sends', 'ivars', 'storeheavy']
SCEN = ['R0', 'R1', 'R2', 'R3', 'R4', 'R5', 'R5n', 'R6']


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

pools = collections.defaultdict(list)
for p in prows:
    if 'kernel' in p:
        pools[(p['cfg'], p['build'], p['kernel'], int(p['workers']))].append(p)
    elif 'scenario' in p:
        pools[(p['cfg'], p['scenario'])].append(p)

groups = collections.defaultdict(list)
for r in krows:
    if 'kernel' not in r or 'FAILED' in r:
        continue
    groups[(r['kernel'], int(r['workers']), r['cfg'], r['build'])].append(r)

failed = [r for r in krows if 'FAILED' in r]
if failed:
    print(f"\nFAILED runs: {len(failed)}")
    for r in failed:
        print('  ', r.get('cfg'), r.get('build'), r.get('kernel'), r.get('workers'), r.get('run'))


def M(k, n, c, key, b='O'):
    return med([fl(r, key) for r in groups.get((k, n, c, b), [])])


def S(k, n, c, key, b='O'):
    return sum(fl(r, key, 0) for r in groups.get((k, n, c, b), []))


def scav(k, n, c, b='O'):
    return [fl(p, 'total') / 1e6 for p in pools.get((c, b, k, n), []) if p.get('kind') in ('scav', 'initial')]


def kinds(k, n, c, kind, b='O'):
    return [p for p in pools.get((c, b, k, n), []) if p.get('kind') == kind]


def cycles(k, n, c, b='O'):
    return [p for p in pools.get((c, b, k, n), []) if p.get('kind') == 'cycle']


# ---------------------------------------------------------------- checksums
print("\n## Checksum gate (every configuration and run against stw)\n")
bad = 0
for k in KERNELS:
    for n in (1, 8):
        ref = {r['checksum'] for r in groups.get((k, n, 'stw', 'O'), [])}
        allc = set()
        runs = 0
        for (kk, nn, c, b), rs in groups.items():
            if kk == k and nn == n:
                for r in rs:
                    allc.add(r['checksum'])
                    runs += 1
        if runs == 0:
            continue
        ok = len(allc) == 1 and allc == ref
        if not ok:
            bad += 1
        print(f"- {k} x{n}: {runs} runs, checksums {'all equal' if ok else 'DIFFER: ' + str(sorted(allc))}")
print(f"\nchecksum mismatches: {bad}")

# ---------------------------------------------------------------- main table
print("\n## 1. Headless matrix\n")
print("| kernel | workers | config | wall ms | vs adr6 | peak RSS MB | promoted MB/s | survived MB | overflow MB | scavenges | scavenge p50 / p99 / max | copied KB/scav | cycles | fallbacks (all runs) | reloc moved MB | checksum |")
print("|---|--:|---|--:|--:|--:|--:|--:|--:|--:|---|--:|--:|--:|--:|---|")
for k in KERNELS:
    for n in (1, 8):
        base = M(k, n, 'adr6', 'ms')
        for c in CFGS:
            rs = groups.get((k, n, c, 'O'), [])
            if not rs:
                continue
            ms = M(k, n, c, 'ms')
            prom = M(k, n, c, 'promoted_mb')
            rate = med([fl(r, 'promoted_mb', 0) / (fl(r, 'ms') / 1000) for r in rs])
            print(f"| {k} | {n} | {c} | {f(ms)} | {f(ms / base if base else None, 2)} | {f(M(k, n, c, 'rss_mb'), 0)} | {f(rate, 0)} "
                  f"| {f(M(k, n, c, 'survived_mb'), 1)} | {f(M(k, n, c, 'overflow_mb'), 1)} | {f(M(k, n, c, 'scavenges'), 0)} | {dist(scav(k, n, c))} "
                  f"| {f(M(k, n, c, 'copied_kb_per_scav'), 0)} | {f(M(k, n, c, 'cycles'), 0)} | {int(S(k, n, c, 'fallback_pauses'))} "
                  f"| {f(M(k, n, c, 'reloc_moved_mb'), 1)} | {rs[0]['checksum']} |")

# ---------------------------------------------------------------- age field
print("\n## 2. Age field: promotion, fallbacks, scavenge cost\n")
print("| kernel | workers | config | promoted MB/s | promoted MB | survived MB | overflow MB | fallbacks (all runs) | full/fallback max ms | scavenge p50 / p99 / max | initial-mark survivor scan p50 / max ms | copied KB/scav | wall ms |")
print("|---|--:|---|--:|--:|--:|--:|--:|--:|---|---|--:|--:|")
for k in ['alloc', 'churn', 'survivors5', 'survivors30', 'oldheap64', 'fragment']:
    for n in (1, 8):
        for c in ['stw', 'adr6', 'n2', 'n4']:
            rs = groups.get((k, n, c, 'O'), [])
            if not rs:
                continue
            rate = med([fl(r, 'promoted_mb', 0) / (fl(r, 'ms') / 1000) for r in rs])
            fb = [fl(p, 'total') / 1e6 for p in pools.get((c, 'O', k, n), []) if p.get('kind') in ('fallback', 'full')]
            ini = [fl(p, 'survroots', 0) / 1e6 for p in kinds(k, n, c, 'initial')]
            print(f"| {k} | {n} | {c} | {f(rate, 0)} | {f(M(k, n, c, 'promoted_mb'), 0)} | {f(M(k, n, c, 'survived_mb'), 1)} | {f(M(k, n, c, 'overflow_mb'), 1)} "
                  f"| {int(S(k, n, c, 'fallback_pauses'))} | {f(max(fb) if fb else None, 2)} | {dist(scav(k, n, c))} "
                  f"| {f(pct(ini, .5), 3)} / {f(max(ini) if ini else None, 3)} | {f(M(k, n, c, 'copied_kb_per_scav'), 0)} | {f(M(k, n, c, 'ms'))} |")

print("\nExtras (alloc, 8 workers, 5 runs): survivor and nursery sizes\n")
print("| config | wall ms | promoted MB/s | survived MB | overflow MB | fallbacks (all runs) | scavenge p50 / p99 / max | copied KB/scav |")
print("|---|--:|--:|--:|--:|--:|---|--:|")
for c in ['adr6', 'n2', 'n2-s1024', 'n2-s1536', 'adr6-nur16', 'n2-nur16']:
    rs = groups.get(('alloc', 8, c, 'O'), [])
    if not rs:
        continue
    rate = med([fl(r, 'promoted_mb', 0) / (fl(r, 'ms') / 1000) for r in rs])
    print(f"| {c} | {f(M('alloc', 8, c, 'ms'))} | {f(rate, 0)} | {f(M('alloc', 8, c, 'survived_mb'), 1)} | {f(M('alloc', 8, c, 'overflow_mb'), 1)} "
          f"| {int(S('alloc', 8, c, 'fallback_pauses'))} | {dist(scav('alloc', 8, c))} | {f(M('alloc', 8, c, 'copied_kb_per_scav'), 0)} |")

# ---------------------------------------------------------------- post-store
print("\n## 3. Post-store check cost (adr6 with the check, nops without; medians)\n")
print("| kernel | workers | build | nops ms | adr6 ms | adr6/nops | stores redone (ragg, all runs) |")
print("|---|--:|---|--:|--:|--:|--:|")
for k in COMPUTE + ['alloc', 'churn', 'survivors30', 'oldheap64', 'oldheap256', 'oldheap512', 'fragment']:
    for n in (1, 8):
        for b in ('O', 'align32'):
            a, z = M(k, n, 'adr6', 'ms', b), M(k, n, 'nops', 'ms', b)
            if a is None or z is None:
                continue
            print(f"| {k} | {n} | {b} | {f(z)} | {f(a)} | {f(a / z, 3)} | {int(S(k, n, 'ragg', 'stores_redone')) if b == 'O' else '-'} |")

# ---------------------------------------------------------------- relocation
print("\n## 4. Relocation activity and conflicts (sums over the 5 runs unless marked p50/max)\n")
print("| kernel | workers | config | reloc cycles | blocks selected | capped | planned MB | moved MB | objects moved | skipped pinned | skipped hazard | no space | CAS failed | blocks evacuated | freed by epoch / at pause | free delay mean / max ms | stores redone | spin episodes / max ms | hazard waits | frame pins | reloc CPU ms | final select max ms | final pause p50 / max |")
print("|---|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|---|--:|---|--:|--:|--:|--:|---|")
for k in ['alloc', 'churn', 'survivors5', 'survivors30', 'oldheap64', 'oldheap256', 'oldheap512', 'fragment']:
    for n in (1, 8):
        for c in RELOC:
            rs = groups.get((k, n, c, 'O'), [])
            if not rs:
                continue
            fin = [(fl(p, 'total', 0) - fl(p, 'verify', 0) - fl(p, 'relocverify', 0)) / 1e6 for p in kinds(k, n, c, 'final')]
            dm = [fl(r, 'free_delay_mean_ms') for r in rs]
            print(f"| {k} | {n} | {c} | {int(S(k, n, c, 'reloc_cycles'))} | {int(S(k, n, c, 'reloc_blocks'))} | {int(S(k, n, c, 'reloc_capped'))} "
                  f"| {f(S(k, n, c, 'reloc_planned_mb'), 1)} | {f(S(k, n, c, 'reloc_moved_mb'), 1)} | {int(S(k, n, c, 'reloc_moved_objs'))} "
                  f"| {int(S(k, n, c, 'reloc_skip_pinned'))} | {int(S(k, n, c, 'reloc_skip_hazard'))} | {int(S(k, n, c, 'reloc_nospace'))} | {int(S(k, n, c, 'reloc_cas_failed'))} "
                  f"| {int(S(k, n, c, 'reloc_evacuated'))} | {int(S(k, n, c, 'freed_epoch'))} / {int(S(k, n, c, 'freed_pause'))} "
                  f"| {f(med(dm), 3)} / {f(max([fl(r, 'free_delay_max_ms', 0) for r in rs]), 3)} "
                  f"| {int(S(k, n, c, 'stores_redone'))} | {int(S(k, n, c, 'spin_episodes'))} / {f(max([fl(r, 'spin_max_ms', 0) for r in rs]), 3)} "
                  f"| {int(S(k, n, c, 'hazard_waits'))} | {int(S(k, n, c, 'frame_pins'))} | {f(S(k, n, c, 'reloc_cpu_ms'), 1)} "
                  f"| {f(max([fl(r, 'final_select_ms_max', 0) for r in rs]), 3)} | {f(pct(fin, .5), 3)} / {f(max(fin) if fin else None, 3)} |")

# per-cycle relocation (pooled cycles)
print("\nPer cycle (pooled over runs, cycles that selected blocks and were applied):\n")
print("| kernel | workers | config | cycles | blocks p50 / max | moved MB p50 / max | evacuated p50 | reloc wall ms p50 / max | reloc CPU ms p50 | relocator MB per CPU s |")
print("|---|--:|---|--:|---|---|--:|---|--:|--:|")
for k in ['alloc', 'survivors30', 'oldheap64', 'oldheap256', 'oldheap512', 'fragment']:
    for n in (1, 8):
        for c in RELOC:
            cs = [p for p in cycles(k, n, c) if fl(p, 'rblocks', 0) > 0 and p.get('applied') == '1']
            if not cs:
                continue
            bl = [fl(p, 'rblocks') for p in cs]
            mv = [fl(p, 'rmoved') / 1048576 for p in cs]
            wall = [fl(p, 'rwall') / 1e6 for p in cs]
            cpu = [fl(p, 'rcpu') / 1e6 for p in cs]
            rate = sum(mv) / (sum(cpu) / 1000) if sum(cpu) > 0 else None
            print(f"| {k} | {n} | {c} | {len(cs)} | {f(pct(bl, .5), 0)} / {f(max(bl), 0)} | {f(pct(mv, .5), 2)} / {f(max(mv), 2)} "
                  f"| {f(pct([fl(p, 'revac') for p in cs], .5), 0)} | {f(pct(wall, .5), 2)} / {f(max(wall), 2)} | {f(pct(cpu, .5), 2)} | {f(rate, 0)} |")

# ---------------------------------------------------------------- footprint
print("\n## 5. Footprint on fragment (median run by wall time; t ms: old space in use MB / live MB)\n")
for n in (1, 8):
    for c in ['stw', 'adr6', 'n2', 'n4', 'r25', 'r50', 'r75', 'ragg']:
        rs = groups.get(('fragment', n, c, 'O'), [])
        if not rs:
            continue
        rs = sorted(rs, key=lambda r: fl(r, 'ms'))
        r = rs[len(rs) // 2]
        pts = r.get('footprint', '').split(',')
        inuse = [float(x.split(':')[1]) for x in pts if x]
        print(f"- x{n} {c}: peak in use {f(max(inuse) if inuse else None, 1)} MB, end {f(inuse[-1] if inuse else None, 1)} MB; "
              + ', '.join(f"{p.split(':')[0]}: {p.split(':')[1]}/{p.split(':')[2]}" for p in pts if p))

# ---------------------------------------------------------------- scenarios
srows = [r for r in srows if 'scenario' in r]
byscen = collections.defaultdict(list)
for r in srows:
    if r.get('verify') == '1':
        continue
    byscen[r['scenario']].append(r)


def median_run(rs):
    rs = sorted(rs, key=lambda r: (fl(r, 'missed'), fl(r, 'gap_max_ms')))
    return rs[len(rs) // 2]


print("\n## 6. Scenarios\n")
print("Median run of 3 (by missed frames, then max gap); pauses of the median run, ms.\n")
print("| id | frames | missed | gap max | worst run-loop iter (VM, GC park, GC enter/leave wait) | scavenges | scav p50 / p99 / max | fallbacks | cycles | final p50 / max | promoted MB | survived MB | overflow MB | reloc moved MB | stores redone | main spins / max ms | per-run missed |")
print("|---|--:|--:|--:|---|--:|---|--:|--:|---|--:|--:|--:|--:|--:|---|---|")
for sc in SCEN:
    rs = byscen.get(sc, [])
    if not rs:
        continue
    r = median_run(rs)
    print(f"| {sc} | {r['frames']} | {r['missed']} | {f(fl(r, 'gap_max_ms'), 3)} | {f(fl(r, 'worst_iter_ms'), 3)} ({f(fl(r, 'worst_iter_vm_ms'), 3)}, {f(fl(r, 'worst_iter_gcpark_ms'), 3)}, {f(fl(r, 'worst_iter_gcenter_ms'), 3)}) "
          f"| {r.get('scavenges', '-')} | {r.get('pause_p50', '-')} / {r.get('pause_p99', '-')} / {r.get('pause_max', '-')} | {r.get('fallback_pauses', '-')} | {r.get('cycles', '-')} "
          f"| {r.get('final_p50', '-')} / {r.get('final_max', '-')} | {f(fl(r, 'promoted_mb'), 0)} | {f(fl(r, 'survived_mb'), 0)} | {f(fl(r, 'overflow_mb'), 0)} "
          f"| {f(fl(r, 'reloc_moved_mb'), 1)} | {r.get('stores_redone', '-')} | {r.get('main_redo', '-')} / {r.get('main_spin_max_ms', '-')} "
          f"| {', '.join(x['missed'] for x in sorted(rs, key=lambda x: int(x.get('run', 0))))} |")

print("\nPauses pooled over all three runs, ms:\n")
print("| id | scavenges | scav p50 / p99 / max | initial (incl. scavenge) p50 / p99 / max | final p50 / p99 / max | fallback p50 / max | ttsp p99 / max | pauses > 4 ms | pauses > 8 ms |")
print("|---|--:|---|---|---|---|---|--:|--:|")
for sc in SCEN:
    ps = [p for p in pools.get(('scenario', sc), [])]
    if not ps:
        continue
    def tot(kind):
        return [(fl(p, 'total', 0) - fl(p, 'relocverify', 0) - fl(p, 'verify', 0)) / 1e6 for p in ps if p.get('kind') == kind]
    sc_ = tot('scav') + tot('initial')
    fb = tot('fallback')
    tt = [fl(p, 'ttsp', 0) / 1e6 for p in ps if p.get('kind') not in ('cycle',)]
    allp = [x for x in tot('scav') + tot('initial') + tot('final') + fb + tot('full')]
    print(f"| {sc} | {len(sc_)} | {dist(tot('scav'))} | {dist(tot('initial'))} | {dist(tot('final'))} | {f(pct(fb, .5), 2)} / {f(max(fb) if fb else None, 2)} "
          f"| {f(pct(tt, .99), 3)} / {f(max(tt) if tt else None, 3)} | {sum(1 for x in allp if x > 4)} | {sum(1 for x in allp if x > 8)} |")

print("\nRelocation in the scenarios (median run):\n")
print("| id | reloc cycles | blocks | moved MB | objects | skipped pinned / hazard / no space | evacuated | freed epoch / pause | free delay mean / max ms | stores redone | spin episodes / max ms | main thread redo / spin max ms | frame pins | final select max ms |")
print("|---|--:|--:|--:|--:|---|--:|---|---|--:|---|---|--:|--:|")
for sc in SCEN:
    rs = byscen.get(sc, [])
    if not rs:
        continue
    r = median_run(rs)
    print(f"| {sc} | {r.get('reloc_cycles')} | {r.get('reloc_blocks')} | {r.get('reloc_moved_mb')} | {r.get('reloc_moved_objs')} "
          f"| {r.get('reloc_skip_pinned')} / {r.get('reloc_skip_hazard')} / {r.get('reloc_nospace')} | {r.get('reloc_evacuated')} "
          f"| {r.get('freed_epoch')} / {r.get('freed_pause')} | {r.get('free_delay_mean_ms')} / {r.get('free_delay_max_ms')} "
          f"| {r.get('stores_redone')} | {r.get('spin_episodes')} / {r.get('spin_max_ms')} | {r.get('main_redo')} / {r.get('main_spin_max_ms')} "
          f"| {r.get('frame_pins')} | {r.get('final_select_ms_max')} |")

print("\nFootprint per second (median run; t ms: old space in use MB / live MB):\n")
for sc in SCEN:
    rs = byscen.get(sc, [])
    if not rs:
        continue
    r = median_run(rs)
    pts = [p for p in r.get('footprint', '').split(',') if p]
    print(f"- {sc}: " + ', '.join(f"{p.split(':')[0]}: {p.split(':')[1]}/{p.split(':')[2]}" for p in pts))

print("\nScenario extras (median runs):\n")
EX = ['build_wait_s', 'max_turn_ms', 'max_turn_kind', 'max_turn_gcenter_ms', 'ev_lat_p50_ms', 'ev_lat_p99_ms', 'ev_lat_max_ms',
      'main_enter_waits', 'main_enter_wait_max_ms', 'mark_cpu_ms_p50', 'sweep_cpu_ms_p50', 'reloc_cpu_ms', 'reloc_wall_ms_max',
      'initial_survroots_ms_max', 'pause_free_ms_max', 'cm_missed', 'old_mb', 'rss_mb']
for sc in SCEN:
    rs = byscen.get(sc, [])
    if not rs:
        continue
    r = median_run(rs)
    print(f"- **{sc}**: " + ', '.join(f"{k}={r.get(k, '-')}" for k in EX))

vr = [r for r in srows if r.get('verify') == '1']
if vr:
    print("\nVerifier on (`--verify`, one run each):\n")
    print("| id | missed frames | cycles | mark verifier runs | missed objects | reloc moved MB | verify failures | final max (with verifier) ms | reloc verifier max ms | fallbacks |")
    print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
    for r in vr:
        print(f"| {r['scenario']} | {r['missed']} | {r.get('cycles')} | {r.get('cm_verify_runs')} | {r.get('cm_missed')} | {r.get('reloc_moved_mb')} "
              f"| {r.get('verifyFailures', '0')} | {r.get('final_max')} | {r.get('reloc_verify_ms_max')} | {r.get('fallback_pauses')} |")
