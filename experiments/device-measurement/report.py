#!/usr/bin/env python3
"""Tables for RESULTS.md from bench-device.sh's raw files.
Usage: report.py results/
Medians over runs; pause distributions: median of per-run p50 and p99, max of
per-run maxima (as ../concurrent-young/report.py)."""
import os
import sys
from statistics import median

D = sys.argv[1] if len(sys.argv) > 1 else 'results'


def parse(name):
    rows = []
    try:
        f = open(os.path.join(D, name))
    except OSError:
        return rows
    for line in f:
        if '=' not in line or line.startswith('#'):
            continue
        d = {}
        for tok in line.split():
            if '=' in tok:
                k, v = tok.split('=', 1)
                d.setdefault(k, v)  # first occurrence wins (run= appears once per line)
        rows.append(d)
    return rows


def num(d, k, default=0.0):
    try:
        return float(d.get(k, default))
    except ValueError:
        return default


def f(x, d=1):
    return ('%.' + str(d) + 'f') % x


def ok(rs):
    return [r for r in rs if 'FAILED' not in r]


def med(rs, k):
    v = [num(r, k) for r in rs if k in r]
    return median(v) if v else None


out = []
P = out.append

# ---------------------------------------------------------------- Part A

# Mac, object-representation RESULTS.md, `O` build: (B/A, C/A).
MAC_A = {('walk', 1): (1.46, 0.98), ('walk', 8): (1.43, 1.00), ('walkbuild', 1): (0.98, 1.00),
         ('walkbuild', 8): (1.03, 0.97), ('sends', 1): (1.04, 1.00), ('sends', 8): (1.06, 1.00),
         ('ivars', 1): (1.00, 1.00), ('ivars', 8): (1.03, 1.00)}
MAC_A_MS = {('walk', 1): (1978.1, 2878.4, 1946.9), ('walk', 8): (235.7, 337.5, 236.0),
            ('walkbuild', 1): (1068.4, 1043.8, 1068.5), ('walkbuild', 8): (143.9, 148.7, 140.0),
            ('sends', 1): (2380.9, 2464.6, 2392.6), ('sends', 8): (313.2, 331.0, 312.9),
            ('ivars', 1): (2184.3, 2189.0, 2180.4), ('ivars', 8): (287.1, 294.9, 287.5)}

a = parse('part-a.txt')
if a:
    m = [r for r in ok(a) if r.get('tag') == 'matrix']
    g = {}
    for r in m:
        g.setdefault((r['kernel'], int(num(r, 'workers')), r['variant']), []).append(r)
    P('\n## Part A: object representation (median of %d runs)\n' % max(len(v) for v in g.values()))
    P('| kernel | w | A ms | B ms | C ms | B/A | C/A | Mac B/A (w=1/8) | Mac C/A | checksums | runs | failed |')
    P('|---|--:|--:|--:|--:|--:|--:|--:|--:|---|--:|--:|')
    fails = [r for r in a if 'FAILED' in r]
    for k in ['walk', 'walkbuild', 'sends', 'ivars']:
        for n in (1, 6):
            ms = {v: med(g.get((k, n, v), []), 'ms') for v in 'ABC'}
            if ms['A'] is None:
                continue
            sums = {r['checksum'] for v in 'ABC' for r in g.get((k, n, v), [])}
            mac = MAC_A.get((k, 1 if n == 1 else 8), ('-', '-'))
            nf = sum(1 for r in fails if 'kernel=%s' % k in ' '.join('%s=%s' % kv for kv in r.items()))
            P('| %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %d | %d |' % (
                k, n, f(ms['A']), f(ms['B']), f(ms['C']), f(ms['B'] / ms['A'], 2), f(ms['C'] / ms['A'], 2),
                mac[0], mac[1], 'equal' if len(sums) == 1 else 'DIFF ' + ','.join(sorted(sums)),
                len(g.get((k, n, 'A'), [])), nf))
    P('\n### Traversal only: walk minus walkbuild (ms), phone against Mac\n')
    P('| w | A | B | C | B/A | C/A | Mac A | Mac B | Mac C | Mac B/A |')
    P('|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|')
    for n in (1, 6):
        t = {}
        for v in 'ABC':
            w, b = med(g.get(('walk', n, v), []), 'ms'), med(g.get(('walkbuild', n, v), []), 'ms')
            t[v] = (w - b) if w is not None and b is not None else None
        if t['A'] is None:
            continue
        mw = MAC_A_MS[('walk', 1 if n == 1 else 8)]
        mb = MAC_A_MS[('walkbuild', 1 if n == 1 else 8)]
        mt = [mw[i] - mb[i] for i in range(3)]
        P('| %d | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (
            n, f(t['A']), f(t['B']), f(t['C']), f(t['B'] / t['A'], 2), f(t['C'] / t['A'], 2),
            f(mt[0]), f(mt[1]), f(mt[2]), f(mt[1] / mt[0], 2)))
    P('\n### Phone against Mac, absolute (A ms; Mac M2 Max `O` build, phone w=6 against Mac w=8)\n')
    P('| kernel | w | phone A | Mac A | phone/Mac |')
    P('|---|--:|--:|--:|--:|')
    for k in ['walk', 'walkbuild', 'sends', 'ivars']:
        for n in (1, 6):
            x = med(g.get((k, n, 'A'), []), 'ms')
            if x is None:
                continue
            y = MAC_A_MS[(k, 1 if n == 1 else 8)][0]
            P('| %s | %d | %s | %s | %s |' % (k, n, f(x), f(y), f(x / y, 2)))
    P('\n### Peak memory per variant (MB, median): phys_footprint peak / getrusage maxrss\n')
    P('| kernel | w | A | B | C | B/A footprint |')
    P('|---|--:|--:|--:|--:|--:|')
    for k in ['walk', 'walkbuild', 'sends', 'ivars', 'compact', 'become']:
        for n in (1, 6):
            fp = {v: med(g.get((k, n, v), []), 'footprint_peak_mb') for v in 'ABC'}
            rs = {v: med(g.get((k, n, v), []), 'rss_mb') for v in 'ABC'}
            if fp['A'] is None:
                continue
            P('| %s | %d | %s / %s | %s / %s | %s / %s | %s |' % (
                k, n, f(fp['A']), f(rs['A'], 0), f(fp['B']), f(rs['B'], 0), f(fp['C']), f(rs['C'], 0), f(fp['B'] / fp['A'], 2)))

    def optable(k, fields, title):
        keys = [(k, 6, v) for v in 'ABC' if (k, 6, v) in g]
        if not keys:
            return
        P('\n### %s (6 workers: 1 operating + 5 running fib; medians)\n' % title)
        P('| variant | ' + ' | '.join(nm for nm, _ in fields) + ' | checksum |')
        P('|---|' + '--:|' * len(fields) + '---|')
        for key in keys:
            rs = g[key]
            cells = []
            for nm, fn in fields:
                try:
                    x = fn(lambda fld: med(rs, fld) or 0.0)
                    cells.append(x if isinstance(x, str) else (f(x, 3) if abs(x) < 10 else f(x, 1)))
                except ZeroDivisionError:
                    cells.append('-')
            cs = sorted({r['checksum'] for r in rs})
            P('| %s | %s | %s |' % (key[2], ' | '.join(cells), cs[0] + ('' if len(cs) == 1 else ' (varies!)')))

    optable('become', [
        ('2-way becomes', lambda m: f(m('becomeCount'), 0)),
        ('fwd path', lambda m: f(m('becomeFwdPath'), 0)),
        ('op us/become', lambda m: 1000 * m('becomeOp_ms') / m('becomeCount')),
        ('pause us/become', lambda m: 1000 * m('becomeStw_ms') / m('becomeCount')),
        ('wall us/become', lambda m: 1000 * m('becomeWall_ms') / m('becomeCount')),
        ('bulk op ms', lambda m: m('forwardOp_ms')),
        ('bulk pause ms', lambda m: m('forwardStw_ms')),
        ('GC before ms', lambda m: m('gc1_ms')),
        ('GC after ms', lambda m: m('gc2_ms')),
        ('ttsp us/stop', lambda m: 1000 * m('ttsp_ms') / m('stwCount')),
    ], 'become: 2^20 live objects, 10 000 two-way becomes, one bulk becomeForward of 100 000')
    optable('compact', [
        ('GC mark ms', lambda m: m('gc3Mark_ms')),
        ('GC sweep ms', lambda m: m('gc3Sweep_ms')),
        ('cmp mark ms', lambda m: m('compactMark_ms')),
        ('plan ms', lambda m: m('compactPlan_ms')),
        ('update ms', lambda m: m('compactUpdate_ms')),
        ('move ms', lambda m: m('compactMove_ms')),
        ('entry sweep ms', lambda m: m('compactSweep_ms')),
        ('compaction pause ms', lambda m: m('compactStw_ms')),
        ('slots updated', lambda m: f(m('compactSlotsUpdated'), 0)),
    ], 'compact: 2^21 allocated, every other one dead')


a2 = parse('part-a2.txt')
if a2:
    g2 = {}
    for r in ok(a2):
        g2.setdefault((r['kernel'], int(num(r, 'workers')), r['variant']), []).append(r)
    P('\n### A2: walk against worker count (per-worker graph 2^22/n nodes), median of 3\n')
    P('| w | nodes per worker | A walk | B walk | B/A walk | A traversal | B traversal | B/A traversal | ns per hop A / B | B footprint peak MB |')
    P('|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|')
    for n in range(1, 7):
        w = {v: med(g2.get(('walk', n, v), []), 'ms') for v in 'AB'}
        wb = {v: med(g2.get(('walkbuild', n, v), []), 'ms') for v in 'AB'}
        if None in w.values() or None in wb.values():
            continue
        t = {v: w[v] - wb[v] for v in 'AB'}
        hops = 2 * (4194304 // n)  # two traversals of the per-worker cycle, workers in parallel
        P('| %d | %d | %s | %s | %s | %s | %s | %s | %s | %s |' % (
            n, 4194304 // n, f(w['A']), f(w['B']), f(w['B'] / w['A'], 2), f(t['A']), f(t['B']), f(t['B'] / t['A'], 2),
            f(t['A'] * 1e6 / hops, 1) + ' / ' + f(t['B'] * 1e6 / hops, 1), f(med(g2.get(('walk', n, 'B'), []), 'footprint_peak_mb'), 0)))

def drift(rows, title, key):
    s = [r for r in ok(rows) if r.get('tag') == 'drift-start']
    e = [r for r in ok(rows) if r.get('tag') == 'drift-end']
    if not s and not e:
        return
    ms = lambda rs: f(median(num(r, key) for r in rs), 1) if rs else '-'
    th = lambda rs: ','.join(r.get('thermal_end', '?') for r in rs)
    P('- %s: start %s (%s), end %s (%s)%s' % (title, ms(s), th(s), ms(e), th(e),
      ', end/start %s' % f(median(num(r, key) for r in e) / median(num(r, key) for r in s), 3) if s and e else ''))


def thermal(rows, title):
    if not rows:
        return
    t0 = min(num(r, 'at') for r in rows)
    states = {}
    first = {}
    for r in rows:
        for k in ('thermal_start', 'thermal_end'):
            st = r.get(k)
            if st:
                states[st] = states.get(st, 0) + 1
                first.setdefault(st, num(r, 'at') - t0)
                first[st] = min(first[st], num(r, 'at') - t0)
    span = (max(num(r, 'at') for r in rows) - t0) / 60
    batt = sorted({r.get('battery', '?') for r in rows})
    lv = [num(r, 'battery_level') for r in rows if 'battery_level' in r]
    P('- %s: %d launches over %s min; thermal samples %s; first seen (min) %s; battery %s, level %s to %s; available memory at start %s to %s MB' % (
        title, len(rows), f(span, 0), ', '.join('%s %d' % kv for kv in sorted(states.items())),
        ', '.join('%s %s' % (k, f(v / 60, 1)) for k, v in sorted(first.items())), '/'.join(batt),
        f(min(lv), 2) if lv else '-', f(max(lv), 2) if lv else '-',
        f(min(num(r, 'avail_start_mb') for r in rows if 'avail_start_mb' in r), 0) if any('avail_start_mb' in r for r in rows) else '-',
        f(max(num(r, 'avail_start_mb') for r in rows if 'avail_start_mb' in r), 0) if any('avail_start_mb' in r for r in rows) else '-'))


# ---------------------------------------------------------------- Part B

b = parse('part-b.txt')
q = parse('part-b-qos.txt')
CFGS = ['adr7', 'stw', 'local', 'offload']
BK = ['alloc', 'churn', 'survivors5', 'survivors30', 'oldheap64', 'oldheap256', 'fragment', 'storeheavy',
      'ivars', 'sends', 'fib', 'arith']
ALLOCK = BK[:8]


def bgroup(rows):
    g = {}
    for r in rows:
        if r.get('tag') not in ('matrix', 'qos'):
            continue
        c = r.get('cfg')
        if r.get('env_KAJO_YC_QOS') == 'utility':
            c += '_ycu'
        if r.get('env_KAJO_CM_QOS') == 'high':
            c += '_cmh'
        g.setdefault((r.get('kernel'), int(num(r, 'workers')), c), []).append(r)
    return g


def dist(rs, name):
    if not rs or not any((name + '_p50') in r for r in rs):
        return '-'
    return '%s / %s / %s' % (f(median(num(r, name + '_p50') for r in rs), 3),
                             f(median(num(r, name + '_p99') for r in rs), 3), f(max(num(r, name + '_max') for r in rs), 3))


if b:
    g = bgroup(b)
    fails = [r for r in b if 'FAILED' in r]
    P('\n## Part B: collector matrix\n')
    P('`stw` is the barrier build with the stop-the-world scavenge (the Mac\'s `adr7b`); `adr7` the -DNO_YOUNG_BARRIER build (checksum reference).')
    P('\n### Wall time, ms (median of runs), 4 MiB nurseries; checksum gate against adr7\n')
    P('| kernel | w | adr7 | stw | local | offload | checksums | stw/adr7 | local/stw | offload/stw | peak footprint MB (max of cfgs) | thermal end (worst) |')
    P('|---|--:|--:|--:|--:|--:|---|--:|--:|--:|--:|---|')
    order = {'nominal': 0, 'fair': 1, 'serious': 2, 'critical': 3}
    for k in BK:
        for n in (1, 2, 6):
            ms, sums, nf = {}, {}, {}
            for c in CFGS:
                rs = g.get((k, n, c), [])
                okr = ok(rs)
                if okr:
                    ms[c] = median(num(r, 'ms') for r in okr)
                    sums[c] = {r.get('checksum') for r in okr}
            if not ms:
                continue
            ref = sums.get('adr7', set())
            bad = [c for c in CFGS if c in sums and (sums[c] != ref or len(sums[c]) != 1)]
            chk = 'equal' if not bad else '**DIFF %s**' % ','.join(bad)
            ratio = lambda x, y: f(ms[x] / ms[y], 3) if x in ms and y in ms else '-'
            allr = [r for c in CFGS for r in ok(g.get((k, n, c), []))]
            fp = max(num(r, 'footprint_peak_mb') for r in allr)
            th = max((r.get('thermal_end', 'nominal') for r in allr), key=lambda s: order.get(s, 9))
            P('| %s | %d | %s | %s | %s | %s | %s | %s | %s |' % (
                k, n, ' | '.join(f(ms[c]) if c in ms else '-' for c in CFGS), chk, ratio('stw', 'adr7'),
                ratio('local', 'stw'), ratio('offload', 'stw'), f(fp, 0), th))
    if fails:
        P('\nFailed launches: %d' % len(fails))
        for r in fails:
            P('- ' + ' '.join('%s=%s' % kv for kv in r.items() if kv[0] not in ('at',)))

    P('\n### Pauses (ms, p50 / p99 / max)\n')
    P('adr7: the stop-the-world scavenge (every worker stopped). local: the owner\'s whole collection. offload: the flip.\n')
    P('| kernel | w | adr7 scavenge | adr7 ttsp | local own | offload flip | local hs latency | offload hs latency | local eden wait max | offload coll waits (n, ms) | offload collector busy % |')
    P('|---|--:|---|---|---|---|---|---|--:|---|--:|')
    for k in ALLOCK:
        for n in (1, 2, 6):
            s = ok(g.get((k, n, 'adr7'), []))
            lo = ok(g.get((k, n, 'local'), []))
            of = ok(g.get((k, n, 'offload'), []))
            if not (s or lo or of):
                continue
            ew = f(max(num(r, 'yc_eden_wait_max') for r in lo), 3) if lo else '-'
            cw = '%d, %s' % (median(num(r, 'coll_waits') for r in of), f(median(num(r, 'coll_wait_ms') for r in of), 1)) if of else '-'
            busy = f(median(num(r, 'collector_busy_pct') for r in of), 1) if of else '-'
            P('| %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (
                k, n, dist(s, 'pause'), dist(s, 'ttsp'), dist(lo, 'own_pause'), dist(of, 'own_pause'),
                dist(lo, 'hs_lat'), dist(of, 'hs_lat'), ew, cw, busy))

    P('\n### Collection activity (medians), 4 MiB\n')
    P('| kernel | w | cfg | collections | promoted MB/s | fallbacks (sum over runs) | initial mark p50 / max ms | marking % | old MB end | peak footprint MB |')
    P('|---|--:|---|--:|--:|--:|---|--:|--:|--:|')
    for k in ALLOCK:
        for n in (1, 2, 6):
            for c in ('adr7', 'local', 'offload'):
                rs = ok(g.get((k, n, c), []))
                if not rs:
                    continue
                colls = median(num(r, 'yc_count') if c != 'adr7' else num(r, 'scavenges') for r in rs)
                prom = median(num(r, 'promotedBytes') / 1048576 / max(num(r, 'ms') / 1000, 1e-9) for r in rs)
                P('| %s | %d | %s | %d | %s | %d | %s / %s | %s | %s | %s |' % (
                    k, n, c, colls, f(prom, 0), sum(num(r, 'fallbacks') for r in rs),
                    f(median(num(r, 'initial_p50') for r in rs), 3), f(max(num(r, 'initial_max') for r in rs), 3),
                    f(median(num(r, 'marking_pct') for r in rs), 1), f(median(num(r, 'old_mb') for r in rs), 1),
                    f(median(num(r, 'footprint_peak_mb') for r in rs), 0)))

if q:
    g = bgroup(q)
    gb = bgroup(b) if b else {}
    P('\n### QoS: collector (offload) and marker thread QoS, 2 and 6 workers (medians)\n')
    P('Defaults (main matrix): collector user-initiated, marker utility. `_ycu`: collector utility. `_cmh`: marker user-initiated.\n')
    P('| kernel | w | cfg | ms | vs default | collector busy % | coll waits (n, ms) | fallbacks (sum) | marking % | initial p50 ms | flip/own p99 ms | checksum vs adr7 |')
    P('|---|--:|---|--:|--:|--:|---|--:|--:|--:|--:|---|')
    for k in ALLOCK:
        for n in (2, 6):
            for c in ('offload', 'offload_ycu', 'offload_cmh', 'local', 'local_cmh'):
                rs = ok((g if '_' in c else gb).get((k, n, c), []))
                if not rs:
                    continue
                base = ok(gb.get((k, n, c.split('_')[0]), []))
                ms = median(num(r, 'ms') for r in rs)
                vs = f(ms / median(num(r, 'ms') for r in base), 3) if base and '_' in c else '-'
                ref = {r.get('checksum') for r in ok(gb.get((k, n, 'adr7'), []))}
                sums = {r.get('checksum') for r in rs}
                chk = 'equal' if ref and sums == ref else ('no ref' if not ref else '**DIFF**')
                P('| %s | %d | %s | %s | %s | %s | %d, %s | %d | %s | %s | %s | %s |' % (
                    k, n, c, f(ms), vs, f(median(num(r, 'collector_busy_pct') for r in rs), 1),
                    median(num(r, 'coll_waits') for r in rs), f(median(num(r, 'coll_wait_ms') for r in rs), 1),
                    sum(num(r, 'fallbacks') for r in rs), f(median(num(r, 'marking_pct') for r in rs), 1),
                    f(median(num(r, 'initial_p50') for r in rs), 3), f(median(num(r, 'own_pause_p99') for r in rs), 3), chk))

# ---------------------------------------------------------------- Part C

SC = ['D0', 'D1', 'D2', 'D3', 'D4', 'D5']


def partc(c, title):
    if c:
        m = [r for r in ok(c) if r.get('tag') == 'matrix']
        P('\n## %s (median run by missed120, then max gap; 10 s at 120 Hz)\n' % title)
        P('| id | Mac id | young | delivered Hz | frames | missed120 | max gap ms | cb late p99 ms | **main stopped because another worker allocated, ms** | main own n / ms / max | main acks other n / ms | main old-space stops (n, ms) | stw pauses (kind n p50/max ms) | thermal start/end | peak footprint MB |')
        P('|---|---|---|--:|--:|--:|--:|--:|--:|---|---|---|---|---|--:|')
        for s in SC:
            rs = [r for r in m if r.get('scenario') == s]
            if not rs:
                continue
            rs.sort(key=lambda r: (num(r, 'missed120'), num(r, 'gap_max_ms')))
            r = rs[len(rs) // 2]
            kinds = []
            for k in ('scav', 'initial', 'final', 'apply', 'fallback', 'full'):
                if ('main_stw_' + k) in r:
                    kinds.append('%s %d, %s' % (k, num(r, 'main_stw_' + k), f(num(r, 'main_stw_' + k + '_ms'), 2)))
            stw = []
            for k in ('scav', 'initial', 'final', 'apply', 'fallback'):
                if ('stw_%s_n' % k) in r:
                    stw.append('%s %d %s/%s' % (k, num(r, 'stw_%s_n' % k), f(num(r, 'stw_%s_p50_ms' % k), 2), f(num(r, 'stw_%s_max_ms' % k), 2)))
            P('| %s | %s | %s | %s | %d | %d | %s | %s | **%s** | %d / %s / %s | %d / %s | %s | %s | %s/%s | %s |' % (
                s, r.get('mac_scenario'), r.get('young', '?'), f(num(r, 'refresh_hz'), 0), num(r, 'frames'), num(r, 'missed120'),
                f(num(r, 'gap_max_ms'), 2), f(num(r, 'cb_late_p99_ms'), 2), f(num(r, 'main_stopped_for_others_ms'), 2),
                num(r, 'main_own_collections', num(r, 'main_own_flips')), f(num(r, 'main_own_ms'), 2), f(num(r, 'main_own_max_ms'), 3),
                num(r, 'main_acks_other'), f(num(r, 'main_acks_other_ms'), 2), '; '.join(kinds) or '-', '; '.join(stw) or '-',
                r.get('thermal_start'), r.get('thermal_end'), f(num(r, 'footprint_peak_mb'), 0)))
        P('\n### All runs: missed120 / max gap ms / main stopped for others ms / thermal end\n')
        for s in SC:
            rs = [r for r in m if r.get('scenario') == s]
            if rs:
                P('- %s: %s' % (s, ', '.join('%d / %s / %s / %s' % (num(r, 'missed120'), f(num(r, 'gap_max_ms'), 1),
                                                                    f(num(r, 'main_stopped_for_others_ms'), 1), r.get('thermal_end')) for r in rs)))
        P('\n### Collector activity in the scenarios (median run)\n')
        P('| id | collections | own pause p50/p99/max ms | hs latency p50/p99/max ms | coll waits n / ms | collector busy % | fallbacks | promoted MB | vm_main_ms | worst iter ms |')
        P('|---|--:|---|---|---|--:|--:|--:|--:|--:|')
        for s in SC:
            rs = [r for r in m if r.get('scenario') == s]
            if not rs:
                continue
            rs.sort(key=lambda r: (num(r, 'missed120'), num(r, 'gap_max_ms')))
            r = rs[len(rs) // 2]
            P('| %s | %d | %s/%s/%s | %s/%s/%s | %d / %s | %s | %d | %s | %s | %s |' % (
                s, num(r, 'yc_count'), f(num(r, 'own_pause_p50'), 3), f(num(r, 'own_pause_p99'), 3), f(num(r, 'own_pause_max'), 3),
                f(num(r, 'hs_lat_p50'), 3), f(num(r, 'hs_lat_p99'), 3), f(num(r, 'hs_lat_max'), 3),
                num(r, 'coll_waits'), f(num(r, 'coll_wait_ms'), 1), f(num(r, 'collector_busy_pct'), 1), num(r, 'fallbacks'),
                f(num(r, 'yc_promoted_mb'), 1), f(num(r, 'vm_main_ms'), 1), f(num(r, 'worst_iter_ms'), 2)))




c = parse('part-c.txt')
if c:
    partc(c, 'Part C: scenarios, first pass (right after Part B, thermal serious)')
c2 = parse('part-c-cool.txt')
if c2:
    partc(c2, 'Part C again after cooling to nominal')

o = parse('part-b-order.txt')
if o:
    P('\n## Run-order check: 1 worker, stw against adr7 (median ms of 3)\n')
    P('| kernel | adr7 first: adr7 / stw | stw first: stw / adr7 | right after a 6-worker offload run: stw / adr7 |')
    P('|---|---|---|---|')
    for k in ('fib', 'ivars', 'alloc'):
        def mm(tag, cfg):
            v = [num(r, 'ms') for r in ok(o) if r.get('tag') == tag and r.get('kernel') == k and r.get('cfg') == cfg and r.get('workers') == '1']
            return f(median(v)) if v else '-'
        P('| %s | %s / %s | %s / %s | %s / %s |' % (k, mm('order-ab', 'adr7'), mm('order-ab', 'stw'), mm('order-ba', 'stw'),
          mm('order-ba', 'adr7'), mm('order-after6', 'stw'), mm('order-after6', 'adr7')))

# ---------------------------------------------------------------- drift, thermal

P('\n## Drift (first kernel of each matrix repeated at start and end, median ms; thermal at end of each run)\n')
drift(a, 'Part A, walk on A, 1 worker', 'ms')
drift(b, 'Part B, alloc stw, 1 worker', 'ms')
drift(q, 'Part B QoS, alloc stw, 1 worker', 'ms')
drift(c, 'Part C, D2 storm local: missed120', 'missed120')
drift(c, 'Part C, D2 storm local: main stopped for others ms', 'main_stopped_for_others_ms')
P('\n## Thermal and battery over each part\n')
thermal(a, 'Part A')
thermal(b, 'Part B')
thermal(q, 'Part B QoS')
thermal(c, 'Part C')
thermal(c2, 'Part C after cool-down')
thermal(parse('cooldown.txt'), 'cool-down probes')
thermal(o, 'run-order check')

print('\n'.join(out))
