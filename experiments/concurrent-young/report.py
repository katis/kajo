#!/usr/bin/env python3
"""Tables for RESULTS.md from bench.sh's raw files (SPEC.md "Headless
matrix", "Scenarios"). Usage: report.py bench-raw-kernels.txt bench-raw-scenarios.txt
Distributions over runs: median of the per-run p50 and p99, max of the max."""
import sys
from statistics import median

def parse(path):
    rows = []
    try:
        f = open(path)
    except OSError:
        return rows
    for line in f:
        if line.startswith('#') or '=' not in line:
            continue
        d = {}
        for tok in line.split():
            if '=' in tok:
                k, v = tok.split('=', 1)
                d[k] = v
        rows.append(d)
    return rows

def num(d, k, default=0.0):
    try:
        return float(d.get(k, default))
    except ValueError:
        return default

CFGS = ['orig', 'adr7', 'adr7b', 'local', 'offload', 'nobarrier']
KERNELS = ['arith', 'fib', 'sends', 'ivars', 'storeheavy', 'alloc', 'churn', 'survivors5', 'survivors30',
           'oldheap64', 'fragment', 'share']

def group(rows):
    g = {}
    for r in rows:
        key = (r.get('kernel'), int(num(r, 'workers')), r.get('cfg'), int(num(r, 'nursery_kb', 4096)))
        g.setdefault(key, []).append(r)
    return g

def f(x, d=1):
    return ('%.' + str(d) + 'f') % x

def kernels(rows):
    g = group(rows)
    out = []
    for nkb in (4096, 16384):
        ks = KERNELS if nkb == 4096 else ['alloc', 'survivors30']
        out.append('\n### Wall time, ms (median of runs), nursery %d KiB; checksum against adr7\n' % (nkb // 1024 * 1024 // 1024))
        out.append('| kernel | w | ' + ' | '.join(CFGS) + ' | checksums | barrier adr7b/adr7 | local/adr7b | offload/adr7b | orig/adr7 |')
        out.append('|---|--:|' + '--:|' * len(CFGS) + '---|--:|--:|--:|--:|')
        for k in ks:
            for n in (1, 8):
                ms = {}
                sums = {}
                fails = {}
                for c in CFGS:
                    rs = g.get((k, n, c, nkb), [])
                    ok = [r for r in rs if 'FAILED' not in r]
                    fails[c] = len(rs) - len(ok)
                    if ok:
                        ms[c] = median(num(r, 'ms') for r in ok)
                        sums[c] = set(r.get('checksum') for r in ok)
                if not ms:
                    continue
                ref = sums.get('adr7', set())
                bad = []
                for c in CFGS:
                    if c in sums and (sums[c] != ref or len(sums[c]) != 1):
                        bad.append(c)
                    if fails.get(c):
                        bad.append('%s:%d failed' % (c, fails[c]))
                chk = 'equal' if not bad else 'DIFF ' + ','.join(bad)
                def ratio(a, b):
                    return f(ms[a] / ms[b], 3) if a in ms and b in ms and ms[b] > 0 else '-'
                cells = [f(ms[c]) if c in ms else '-' for c in CFGS]
                out.append('| %s | %d | %s | %s | %s | %s | %s | %s |' % (k, n, ' | '.join(cells), chk,
                           ratio('adr7b', 'adr7'), ratio('local', 'adr7b'), ratio('offload', 'adr7b'), ratio('orig', 'adr7')))
    return '\n'.join(out)

def dist(rs, name):
    p50 = [num(r, name + '_p50') for r in rs]
    p99 = [num(r, name + '_p99') for r in rs]
    mx = [num(r, name + '_max') for r in rs]
    if not rs:
        return '-'
    return '%s / %s / %s' % (f(median(p50), 3), f(median(p99), 3), f(max(mx), 3))

ALLOCK = ['alloc', 'churn', 'survivors5', 'survivors30', 'oldheap64', 'fragment', 'share']

def pauses(rows):
    g = group(rows)
    out = ['\n### Pauses of the allocating worker (ms, p50 / p99 / max), 4 MiB unless stated\n',
           'adr7: the stop-the-world scavenge, every worker stopped. local: the owning worker\'s whole collection. offload: the flip.\n',
           '| kernel | w | nursery | adr7 scavenge | local own | offload flip | local hs latency | offload hs latency | local rounds mean/max | offload rounds mean/max | local eden wait max | offload coll waits (n, ms) | offload collector busy % |',
           '|---|--:|--:|---|---|---|---|---|---|---|--:|---|--:|']
    for nkb in (4096, 16384):
        for k in ALLOCK:
            if nkb == 16384 and k not in ('alloc', 'survivors30'):
                continue
            for n in (1, 8):
                a = [r for r in g.get((k, n, 'adr7', nkb), []) if 'FAILED' not in r]
                lo = [r for r in g.get((k, n, 'local', nkb), []) if 'FAILED' not in r]
                of = [r for r in g.get((k, n, 'offload', nkb), []) if 'FAILED' not in r]
                if not (a or lo or of):
                    continue
                def rounds(rs):
                    if not rs:
                        return '-'
                    return '%s / %d' % (f(median(num(r, 'yc_rounds_mean') for r in rs), 2), max(int(num(r, 'yc_rounds_max')) for r in rs))
                ew = f(max(num(r, 'yc_eden_wait_max') for r in lo), 3) if lo else '-'
                cw = '%d, %s' % (median(num(r, 'coll_waits') for r in of), f(median(num(r, 'coll_wait_ms') for r in of), 1)) if of else '-'
                busy = f(median(num(r, 'collector_busy_pct') for r in of), 1) if of else '-'
                out.append('| %s | %d | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (
                    k, n, nkb // 1024, dist(a, 'pause'), dist(lo, 'own_pause'), dist(of, 'own_pause'),
                    dist(lo, 'hs_lat'), dist(of, 'hs_lat'), rounds(lo), rounds(of), ew, cw, busy))
    out.append('\n### Barrier and collection activity (medians of runs), 4 MiB\n')
    out.append('| kernel | w | cfg | collections | promoted MB/s | fallbacks | del records | cross-nursery holders (barrier) | holders scanned | resume scans | initial mark p50 / max ms |')
    out.append('|---|--:|---|--:|--:|--:|--:|--:|--:|--:|---|')
    for k in ALLOCK:
        for n in (1, 8):
            for c in ('adr7', 'local', 'offload'):
                rs = [r for r in g.get((k, n, c, 4096), []) if 'FAILED' not in r]
                if not rs:
                    continue
                colls = median(num(r, 'yc_count') if c != 'adr7' else num(r, 'scavenges') for r in rs)
                prom = median(num(r, 'promotedBytes') / 1048576 / max(num(r, 'ms') / 1000, 1e-9) for r in rs)
                out.append('| %s | %d | %s | %d | %s | %d | %d | %d | %d | %d | %s / %s |' % (
                    k, n, c, colls, f(prom, 0), median(num(r, 'fallbacks') for r in rs),
                    median(num(r, 'yc_del_records') for r in rs), median(num(r, 'cross_rem_barrier') for r in rs),
                    median(num(r, 'yc_holders') for r in rs), median(num(r, 'resume_scans') for r in rs),
                    f(median(num(r, 'initial_p50') for r in rs), 3), f(max(num(r, 'initial_max') for r in rs), 3)))
    return '\n'.join(out)

SC = ['Y0', 'Y1', 'Y2', 'Y3', 'Y4l', 'Y4o', 'Y5l', 'Y5o', 'Y6']

def scenarios(rows):
    out = ['\n### Scenarios (median run by missed120, then max gap; 10 s)\n',
           '| id | young | display Hz | frames | missed (display) | missed120 | max gap ms | worst iter ms | main stopped for others ms | main own n / ms / max | main coll waits n / ms | main acks own n / ms | main acks other n / ms | main stops by kind (n, ms) | stw pauses (kind n p50/max ms) |',
           '|---|---|--:|--:|--:|--:|--:|--:|--:|---|---|---|---|---|---|']
    ver = []
    for s in SC:
        rs = [r for r in rows if r.get('scenario') == s and r.get('verify') == '0']
        vs = [r for r in rows if r.get('scenario') == s and r.get('verify') == '1']
        ver += vs
        if not rs:
            continue
        rs.sort(key=lambda r: (num(r, 'missed120'), num(r, 'gap_max_ms')))
        r = rs[len(rs) // 2]
        kinds = []
        for k in ('scav', 'initial', 'final', 'apply', 'fallback', 'full', 'verify'):
            if ('main_stw_' + k) in r:
                kinds.append('%s %d, %s' % (k, num(r, 'main_stw_' + k), f(num(r, 'main_stw_' + k + '_ms'), 2)))
        stw = []
        for k in ('scav', 'initial', 'final', 'apply', 'fallback'):
            if ('stw_%s_n' % k) in r:
                stw.append('%s %d %s/%s' % (k, num(r, 'stw_%s_n' % k), f(num(r, 'stw_%s_p50_ms' % k), 2), f(num(r, 'stw_%s_max_ms' % k), 2)))
        out.append('| %s | %s | %s | %d | %d | %d | %s | %s | %s | %d / %s / %s | %d / %s | %d / %s | %d / %s | %s | %s |' % (
            s, r.get('young', '?'), f(num(r, 'refresh_hz'), 0), num(r, 'frames'), num(r, 'missed'), num(r, 'missed120'),
            f(num(r, 'gap_max_ms'), 2), f(num(r, 'worst_iter_ms'), 2), f(num(r, 'main_stopped_for_others_ms'), 2),
            num(r, 'main_own_collections', num(r, 'main_own_flips')), f(num(r, 'main_own_ms'), 2), f(num(r, 'main_own_max_ms'), 3),
            num(r, 'main_coll_waits'), f(num(r, 'main_coll_wait_ms'), 2),
            num(r, 'main_acks_own'), f(num(r, 'main_acks_own_ms'), 2), num(r, 'main_acks_other'), f(num(r, 'main_acks_other_ms'), 2),
            '; '.join(kinds) or '-', '; '.join(stw) or '-'))
    out.append('\n### Scenario runs: all three, missed120 / max gap ms\n')
    for s in SC:
        rs = [r for r in rows if r.get('scenario') == s and r.get('verify') == '0']
        if rs:
            out.append('- %s: %s' % (s, ', '.join('%d / %s' % (num(r, 'missed120'), f(num(r, 'gap_max_ms'), 1)) for r in rs)))
    out.append('\n### Collector activity in the scenarios (median run)\n')
    out.append('| id | collections | own pause p50/p99/max ms | hs latency p50/p99/max ms | hs worst by worker | rounds mean/max | coll waits (all workers) n / ms | collector busy % | fallbacks | promoted MB |')
    out.append('|---|--:|---|---|--:|---|---|--:|--:|--:|')
    for s in SC:
        rs = [r for r in rows if r.get('scenario') == s and r.get('verify') == '0']
        if not rs:
            continue
        rs.sort(key=lambda r: (num(r, 'missed120'), num(r, 'gap_max_ms')))
        r = rs[len(rs) // 2]
        out.append('| %s | %d | %s/%s/%s | %s/%s/%s | %s | %s / %d | %d / %s | %s | %d | %s |' % (
            s, num(r, 'yc_count'), f(num(r, 'own_pause_p50'), 3), f(num(r, 'own_pause_p99'), 3), f(num(r, 'own_pause_max'), 3),
            f(num(r, 'hs_lat_p50'), 3), f(num(r, 'hs_lat_p99'), 3), f(num(r, 'hs_lat_max'), 3), r.get('hs_worst_by', '-'),
            f(num(r, 'yc_rounds_mean'), 2), num(r, 'yc_rounds_max'), num(r, 'coll_waits'), f(num(r, 'coll_wait_ms'), 1),
            f(num(r, 'collector_busy_pct'), 1), num(r, 'fallbacks'), f(num(r, 'yc_promoted_mb'), 1)))
    if ver:
        out.append('\n### Verifier runs\n')
        for r in ver:
            out.append('- %s --verify: verifyFailures=%s young_verify_runs=%s cm_verify_runs=%s reloc_verify=%s missed120=%s' % (
                r.get('scenario'), r.get('verifyFailures', '0'), r.get('youngVerifyRuns', '0'), r.get('cm_verify_runs', '0'),
                r.get('relocVerifyRuns', '0'), r.get('missed120')))
    return '\n'.join(out)

def initial(rows):
    g = group(rows)
    out = ['\n### Initial-mark pause, 8 workers: (a) young-root scan vs (b) forced global scavenge (ms, p50 / max over runs; scan part p50)\n',
           '| kernel | local (a) | local (b) | offload (a) | offload (b) | (a) young-scan part p50 / max | (b) scavenge part p50 |',
           '|---|---|---|---|---|---|---|']
    for k in ['alloc', 'survivors30', 'oldheap64', 'fragment', 'share']:
        cells = []
        for c in ('local', 'localb', 'offload', 'offloadb'):
            rs = [r for r in g.get((k, 8, c, 4096), []) if 'FAILED' not in r and num(r, 'cycles') > 0]
            cells.append('%s / %s (%d cycles)' % (f(median(num(r, 'initial_p50') for r in rs), 3), f(max(num(r, 'initial_max') for r in rs), 3),
                         median(num(r, 'cycles') for r in rs)) if rs else '-')
        ra = [r for r in g.get((k, 8, 'local', 4096), []) + g.get((k, 8, 'offload', 4096), []) if 'FAILED' not in r and num(r, 'cycles') > 0]
        rb = [r for r in g.get((k, 8, 'localb', 4096), []) + g.get((k, 8, 'offloadb', 4096), []) if 'FAILED' not in r and num(r, 'cycles') > 0]
        sa = '%s / %s' % (f(median(num(r, 'initial_survroots_ms_p50') for r in ra), 3), f(max(num(r, 'initial_survroots_ms_max') for r in ra), 3)) if ra else '-'
        sb = f(median(num(r, 'initial_scav_p50') for r in rb), 3) if rb else '-'
        out.append('| %s | %s | %s | %s |' % (k, ' | '.join(cells), sa, sb))
    return '\n'.join(out)

def main():
    krows = parse(sys.argv[1]) if len(sys.argv) > 1 else []
    srows = parse(sys.argv[2]) if len(sys.argv) > 2 else []
    if krows:
        print(kernels(krows))
        print(pauses(krows))
        print(initial(krows))
    if srows:
        print(scenarios(srows))

main()
