#!/usr/bin/env python3
"""Tables for RESULTS.md from the raw lines in results/ (SPEC.md lists the
keys). Every table is printed as markdown; `./report.py > bench-output.txt`.

Part 1 per hop, per launch: (walk22x4 - median walkbuild22 of the same
companion) / (4 x 2^22) for time, the same for energy; 2 workers: walk23x4
minus walkbuild23, energy over 2 x 4 x 2^22 hops, time over 4 x 2^22 (each
worker walks its own graph concurrently)."""
import os
import re
import statistics
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
R = os.path.join(HERE, 'results')


def parse(name):
    rows = []
    p = os.path.join(R, name)
    if not os.path.exists(p):
        return rows
    for line in open(p):
        line = line.strip()
        if not line or 'FAILED=1' in line:
            continue
        d = {}
        for tok in line.split(' '):
            if '=' in tok:
                k, v = tok.split('=', 1)
                d.setdefault(k, v)  # first occurrence wins
        rows.append(d)
    return rows


def failed(name):
    p = os.path.join(R, name)
    return sum(1 for l in open(p) if 'FAILED=1' in l) if os.path.exists(p) else 0


def num(d, k, default=None):
    try:
        return float(d[k])
    except (KeyError, ValueError):
        return default


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def f(x, d=1):
    if x is None:
        return '-'
    return ('%.' + str(d) + 'f') % x


def spread(xs, d=0):
    xs = sorted(x for x in xs if x is not None)
    return ', '.join(f(x, d) for x in xs)


def thermal_counts(rows):
    c = defaultdict(int)
    for r in rows:
        c[r.get('thermal_end', '?')] += 1
    return ', '.join('%s %d' % (k, v) for k, v in sorted(c.items()))


# ---------------------------------------------------------------- Part 1

COMP_NAMES = {
    'none': 'alone (idle cluster)',
    'spin': 'companion spinning (user-initiated)',
    't10000': 'companion timer 10 kHz',
    't1000': 'companion timer 1 kHz',
    't100': 'companion timer 100 Hz',
    'spinut': 'companion spinning at utility QoS',
    'wfe': 'companion in a `wfe` loop',
    '2w': 'second worker, own graph (2 x 2^22)',
}
SLOW_NS = 300.0  # walk22 per-hop: fast regime 150 to 250, slow 350 and up


def p1_rows():
    rows = [r for r in parse('dev-p1.txt') if r.get('tag') in ('matrix', 'drift-start', 'drift-end')]
    return rows


def p1_key(r):
    if r.get('workers') == '2':
        return '2w'
    return r.get('comp_cfg', 'none')


def p1_perhop(rows):
    """[(cfg, launch row, ns/hop, nJ/hop process, nJ/hop worker)]"""
    builds = defaultdict(list)
    for r in rows:
        if r.get('kernel', '').startswith('walkbuild') and r.get('tag') == 'matrix':
            builds[p1_key(r)].append(r)
    out = []
    for r in rows:
        k = r.get('kernel', '')
        if not k.startswith('walk') or k.startswith('walkbuild'):
            continue
        cfg = p1_key(r)
        b = builds.get(cfg) or builds.get('none')
        bms = med([num(x, 'ms') for x in b])
        be = med([num(x, 'energy_mj') for x in b])
        bce = med([num(x, 'comptc_energy_mj', 0) for x in b])
        reps = int(r.get('reps', 4))
        nodes = 2 ** 22
        workers = int(r.get('workers', 1))
        hops_wall = reps * nodes
        hops_all = hops_wall * workers
        ns = (num(r, 'ms') - bms) * 1e6 / hops_wall
        e = (num(r, 'energy_mj') - be) * 1e6 / hops_all
        ce = num(r, 'comptc_energy_mj', 0) - bce
        ew = (num(r, 'energy_mj') - num(r, 'comptc_energy_mj', 0) - (be - bce)) * 1e6 / hops_all
        out.append((cfg, r, ns, e, ew, ce * 1e6 / hops_all))
    return out, builds


def part1():
    rows = p1_rows()
    if not rows:
        return
    ph, builds = p1_perhop(rows)
    order = ['none', 'spin', 't10000', 't1000', 't100', 'spinut', 'wfe', '2w']
    mat = [x for x in ph if x[1].get('tag') == 'matrix']
    print('\n### Part 1: walk22 on B (1 worker, 4 traversals), per hop, medians of launches\n')
    print('Energy = `ri_energy_nj` of the process (all threads); "worker" = process minus the companion thread\'s own '
          'energy (PROC_PIDTHREADCOUNTS). Build (walkbuild22, same companion) subtracted per configuration.\n')
    print('| configuration | launches | ns/hop | slow launches | nJ/hop process | nJ/hop worker | nJ/hop companion | '
          'companion CPU ms (run) | companion P share | companion W | worker+rest W | process W | P share | IPC |')
    print('|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|')
    for c in order:
        xs = [x for x in mat if x[0] == c]
        if not xs:
            continue
        rs = [x[1] for x in xs]
        slow = sum(1 for x in xs if x[2] > SLOW_NS)
        wall = [num(r, 'win_ms') / 1000 for r in rs]
        pw = med([num(r, 'energy_mj') / 1000 / w for r, w in zip(rs, wall)])
        cw = med([num(r, 'comptc_energy_mj', 0) / 1000 / w for r, w in zip(rs, wall)])
        ww = med([(num(r, 'energy_mj') - num(r, 'comptc_energy_mj', 0)) / 1000 / w for r, w in zip(rs, wall)])
        print('| %s | %d | %s | %d of %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (
            COMP_NAMES.get(c, c), len(xs), f(med([x[2] for x in xs])), slow, len(xs),
            f(med([x[3] for x in xs])), f(med([x[4] for x in xs])), f(med([x[5] for x in xs])),
            f(med([num(r, 'comp_cpu_ms', 0) for r in rs]), 0), f(med([num(r, 'comptc_p_frac') for r in rs]), 2),
            f(cw, 2), f(ww, 2), f(pw, 2), f(med([num(r, 'p_frac') for r in rs]), 3), f(med([num(r, 'ipc') for r in rs]), 2)))
    print('\nPer launch (sorted; the regime is per launch, so medians hide it):\n')
    print('| configuration | ns/hop per launch | nJ/hop process per launch | nJ/hop worker per launch |')
    print('|---|---|---|---|')
    for c in order:
        xs = [x for x in mat if x[0] == c]
        if not xs:
            continue
        xs = sorted(xs, key=lambda x: x[2])
        print('| %s | %s | %s | %s |' % (COMP_NAMES.get(c, c), ', '.join(f(x[2], 0) for x in xs),
                                         ', '.join(f(x[3], 0) for x in xs), ', '.join(f(x[4], 0) for x in xs)))
    # Regime split: energy per hop within slow and fast launches
    print('\nBy regime (all single-worker launches without a spinning or wfe companion, split at %d ns/hop):\n' % SLOW_NS)
    print('| regime | launches | ns/hop median | nJ/hop process | process W | P GHz | IPC |')
    print('|---|--:|--:|--:|--:|--:|--:|')
    for name, cond in (('slow', lambda x: x[2] > SLOW_NS), ('fast', lambda x: x[2] <= SLOW_NS)):
        xs = [x for x in mat if x[0] in ('none', 't100', 't1000', 't10000', 'spinut') and cond(x)]
        if not xs:
            continue
        rs = [x[1] for x in xs]
        print('| %s | %d (%s) | %s | %s | %s | %s | %s |' % (
            name, len(xs), ', '.join(sorted(set(x[0] for x in xs))), f(med([x[2] for x in xs])), f(med([x[3] for x in xs])),
            f(med([num(r, 'energy_mj') / num(r, 'win_ms') for r in rs]), 2), f(med([num(r, 'p_ghz') for r in rs]), 2),
            f(med([num(r, 'ipc') for r in rs]), 2)))
    print('\nCompanion behaviour (medians over walk launches):\n')
    print('| companion | QoS seen | wakeups or iterations per s | mean lateness us | CPU ms per s of run | its energy mW |')
    print('|---|---|--:|--:|--:|--:|')
    for c in order[1:-1]:
        rs = [x[1] for x in mat if x[0] == c]
        if not rs:
            continue
        print('| %s | %s | %s | %s | %s | %s |' % (
            c, rs[0].get('comp_qos', '-'), f(med([num(r, 'comp_rate_hz') for r in rs]), 0),
            f(med([num(r, 'comp_late_mean_us') for r in rs]), 1),
            f(med([num(r, 'comp_cpu_ms') / num(r, 'comp_wall_ms') * 1000 for r in rs]), 0),
            f(med([num(r, 'comptc_energy_mj', 0) / num(r, 'comp_wall_ms') * 1000 for r in rs]), 0)))
    print('\nBuild (walkbuild22 / walkbuild23 x 2), medians: ms, energy mJ, companion energy mJ\n')
    print('| configuration | launches | ms | energy mJ | companion mJ |')
    print('|---|--:|--:|--:|--:|')
    for c in order:
        b = builds.get(c, [])
        if b:
            print('| %s | %d | %s | %s | %s |' % (c, len(b), f(med([num(r, 'ms') for r in b])),
                                                f(med([num(r, 'energy_mj') for r in b])),
                                                f(med([num(r, 'comptc_energy_mj', 0) for r in b]))))
    ck = set(r.get('checksum') for r in rows if r.get('kernel') == 'walk22x4')
    print('\nwalk22x4 checksums: %s; failed launches: %d; thermal at line ends: %s' % (
        'equal' if len(ck) == 1 else 'DIFFER %s' % ck, failed('dev-p1.txt'), thermal_counts(rows)))


def chase():
    rows = [r for r in parse('dev-p1chase.txt') if r.get('tag') == 'matrix']
    if not rows:
        return
    print('\n### Part 1: chase 256 MB, 1 thread, no VM (2^25 timed hops)\n')
    print('Process energy over the timed hops only; the companion\'s share of it is its energy scaled to the hop window.\n')
    print('| companion | launches | ns/hop (per launch) | nJ/hop process (per launch) | nJ/hop without companion | process W | IPC |')
    print('|---|--:|---|---|--:|--:|--:|')
    for c in ('none', 'spin', 'wfe'):
        rs = [r for r in rows if r.get('comp_cfg') == c]
        if not rs:
            continue
        hops = [num(r, 'hops') for r in rs]
        e = [num(r, 'energy_mj') * 1e6 / h for r, h in zip(rs, hops)]
        cs = [num(r, 'comptc_energy_mj', 0) * num(r, 'hop_ms') / num(r, 'comp_wall_ms', 1) if c != 'none' else 0 for r in rs]
        ew = [(num(r, 'energy_mj') - x) * 1e6 / h for r, x, h in zip(rs, cs, hops)]
        print('| %s | %d | %s (%s) | %s (%s) | %s | %s | %s |' % (
            c, len(rs), f(med([num(r, 'ns_hop') for r in rs])), spread([num(r, 'ns_hop') for r in rs]),
            f(med(e)), spread(e), f(med(ew)), f(med([num(r, 'energy_mj') / num(r, 'hop_ms') for r in rs]), 2),
            f(med([num(r, 'ipc') for r in rs]), 3)))


# ---------------------------------------------------------------- Part 2

CFGS = ['stw', 'conc-high', 'conc-utility', 'conc-mixed']


def p2_group(name):
    g = defaultdict(list)
    for r in parse(name):
        if r.get('tag') != 'matrix':
            continue
        g[(float(r.get('rate_mb_s', 0)), r.get('cfg'))].append(r)
    return g


def vm_energy(r):
    return sum(num(r, k, 0) for k in ('main_energy_mj', 'coll_energy_mj', 'marker_energy_mj'))


def part2(name='dev-p2.txt', label='rate matrix'):
    g = p2_group(name)
    if not g:
        return
    rates = sorted(set(k[0] for k in g))
    print('\n### Part 2 (%s, `%s`): energy per MB allocated, medians of launches\n' % (label, name))
    print('mJ/MB = process energy over the window / MB the frames allocated (24-byte PPoint bodies and OHPoint churn). '
          'VM mJ/MB = main + collector + marker threads only (PROC_PIDTHREADCOUNTS).\n')
    print('| MB/s | ' + ' | '.join('%s mJ/MB' % c for c in CFGS) + ' | ' + ' | '.join('%s VM mJ/MB' % c for c in CFGS) + ' |')
    print('|--:|' + '--:|' * (2 * len(CFGS)))
    for rt in rates:
        a, b = [], []
        for c in CFGS:
            rs = g.get((rt, c), [])
            a.append(f(med([num(r, 'energy_mj') / num(r, 'alloc_mb') for r in rs]), 2) if rs else '-')
            b.append(f(med([vm_energy(r) / num(r, 'alloc_mb') for r in rs]), 2) if rs else '-')
        print('| %g | %s | %s |' % (rt, ' | '.join(a), ' | '.join(b)))
    print('\nPer configuration and rate (medians; sums where marked):\n')
    print('| MB/s | cfg | n | alloc MB/s | energy J | process W | main CPU s | main J | coll CPU s | coll P share | coll J | '
          'marker CPU s | marker P share | marker J | cycles (done) | fallbacks (sum) | scavenges or collections | '
          'main pause p50 / p99 / max ms | missed120 (sum, max) | old HWM MB | thermal end |')
    print('|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|--:|--:|---|---|--:|---|')
    for rt in rates:
        for c in CFGS:
            rs = g.get((rt, c), [])
            if not rs:
                continue
            def m(k, sc=1.0, d=2):
                return f(med([num(r, k, 0) * sc for r in rs]), d)
            if c == 'stw':
                pz = '%s / %s / %s' % (m('pause_p50', 1, 3), m('pause_p99', 1, 3), m('pause_max', 1, 3))
                coll = m('scavenges', 1, 0)
                cyc = '%s full' % m('fulls', 1, 0)
                fb = '-'
            else:
                pz = '%s / %s / %s' % (m('main_own_p50_ms', 1, 3), m('main_own_p99_ms', 1, 3), m('main_own_max_ms', 1, 3))
                coll = m('yc_count', 1, 0)
                cyc = '%s (%s)' % (m('cycles', 1, 0), m('cycles_done', 1, 0))
                fb = str(int(sum(num(r, 'fallbacks', 0) for r in rs)))
            mis = [num(r, 'missed120', 0) for r in rs]
            print('| %g | %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %d, %d | %s | %s |' % (
                rt, c, len(rs), m('alloc_mb_s', 1, 1), m('energy_mj', 1e-3), f(med([num(r, 'energy_mj') / num(r, 'win_ms') for r in rs]), 2),
                m('main_cpu_ms', 1e-3), m('main_energy_mj', 1e-3), m('coll_cpu_ms', 1e-3), m('coll_p_frac', 1, 2),
                m('coll_energy_mj', 1e-3, 3), m('marker_cpu_ms', 1e-3), m('marker_p_frac', 1, 2), m('marker_energy_mj', 1e-3, 3),
                cyc, fb, coll, pz, sum(mis), max(mis), m('old_hwm_mb', 1, 0), thermal_counts(rs)))
    print('\nCollector and marker CPU against the mutator, and energy per CPU second (medians):\n')
    print('| MB/s | cfg | coll+marker CPU / main CPU | main mJ per CPU s | coll mJ per CPU s | marker mJ per CPU s | '
          'coll waits (n, ms) | collector busy % | marking % | mark MB per CPU s |')
    print('|--:|---|--:|--:|--:|--:|---|--:|--:|--:|')
    for rt in rates:
        for c in CFGS[1:]:
            rs = g.get((rt, c), [])
            if not rs:
                continue
            def ratio(a, b):
                return med([num(r, a, 0) / num(r, b) if num(r, b) else None for r in rs])
            print('| %g | %s | %s | %s | %s | %s | %s, %s | %s | %s | %s |' % (
                rt, c, f(med([(num(r, 'coll_cpu_ms', 0) + num(r, 'marker_cpu_ms', 0)) / num(r, 'main_cpu_ms') for r in rs]), 3),
                f(ratio('main_energy_mj', 'main_cpu_ms') * 1000 if ratio('main_energy_mj', 'main_cpu_ms') else None, 0),
                f(ratio('coll_energy_mj', 'coll_cpu_ms') * 1000 if ratio('coll_energy_mj', 'coll_cpu_ms') else None, 0),
                f(ratio('marker_energy_mj', 'marker_cpu_ms') * 1000 if ratio('marker_energy_mj', 'marker_cpu_ms') else None, 0),
                f(med([num(r, 'coll_waits', 0) for r in rs]), 0), f(med([num(r, 'coll_wait_ms', 0) for r in rs]), 1),
                f(med([num(r, 'collector_busy_pct', 0) for r in rs]), 1), f(med([num(r, 'marking_pct', 0) for r in rs]), 1),
                f(med([num(r, 'mark_mb_per_cpu_s', 0) for r in rs]), 0)))
    print('\nPer launch, fallbacks / missed120 / cycles done (in run order per cell):\n')
    print('| MB/s | ' + ' | '.join(CFGS) + ' |')
    print('|--:|' + '---|' * len(CFGS))
    for rt in rates:
        cells = []
        for c in CFGS:
            rs = g.get((rt, c), [])
            cells.append(', '.join('%d/%d/%d' % (num(r, 'fallbacks', 0), num(r, 'missed120', 0), num(r, 'cycles_done', 0)) for r in rs))
        print('| %g | %s |' % (rt, ' | '.join(cells)))
    allrows = [r for v in g.values() for r in v]
    print('\nFailed launches: %d; thermal at line ends: %s' % (failed(name), thermal_counts(allrows)))


# ---------------------------------------------------------------- Part 3

MODES = [('novm', 'conc-utility'), ('parked', 'conc-utility'), ('link', 'conc-utility'), ('tick', 'conc-utility'),
         ('tickalloc', 'conc-utility'), ('tickalloc', 'conc-high')]


def part3():
    rows = [r for r in parse('dev-p3.txt') if r.get('tag') == 'matrix']
    if not rows:
        return
    print('\n### Part 3: idle, 60 s windows, medians of launches (per second of window)\n')
    print('| mode | cfg | n | idle wakeups/s | interrupt wakeups/s | CPU ms/s | energy mW | main CPU ms/s | marker CPU ms/s | '
          'collector CPU ms/s | bg workers CPU ms/s | other threads CPU ms/s | frames/s |')
    print('|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|')
    for m, c in MODES:
        rs = [r for r in rows if r.get('mode') == m and (m in ('novm', 'parked', 'link', 'tick') or r.get('cfg') == c)]
        if not rs:
            continue
        def ps(k, sc=1.0, d=1):
            return f(med([num(r, k, 0) * sc / (num(r, 'win_ms') / 1000) for r in rs]), d)
        print('| %s | %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (
            m, c if m == 'tickalloc' else '-', len(rs), ps('idle_wkups'), ps('intr_wkups'), ps('cpu_ms', 1, 2),
            ps('energy_mj', 1, 2), ps('main_cpu_thread_ms', 1, 2), ps('marker_cpu_thread_ms', 1, 2),
            ps('coll_cpu_thread_ms', 1, 2), ps('bg_cpu_thread_ms', 1, 3), ps('other_cpu_ms', 1, 2),
            f(med([num(r, 'refresh_hz') for r in rs]), 1) if m not in ('novm', 'parked') else '-'))
    print('\nThreads that ran in the window (first launch of each mode; ms of CPU over the window):\n')
    for m, c in MODES:
        rs = [r for r in rows if r.get('mode') == m and (m in ('novm', 'parked', 'link', 'tick') or r.get('cfg') == c)]
        if rs:
            print('- %s%s: `%s`' % (m, ' ' + c if m == 'tickalloc' else '', rs[0].get('threads', '')))
    print('\nFailed launches: %d; thermal at line ends: %s' % (failed('dev-p3.txt'), thermal_counts(rows)))


# ---------------------------------------------------------------- thermal

def drift():
    print('\n### Thermal drift: the first configuration repeated at the end of each matrix\n')
    print('| file | configuration | start | end | end/start | thermal at line ends |')
    print('|---|---|--:|--:|--:|---|')
    for name, key, label in (('dev-p1.txt', 'ms', 'walk22x4 alone, ms'), ('dev-p2.txt', 'energy_mj', 'stw 2 MB/s, energy mJ'),
                             ('dev-p2quiet.txt', 'energy_mj', 'stw 1 MB/s, energy mJ'), ('dev-p3.txt', 'energy_mj', 'novm, energy mJ')):
        rows = parse(name)
        s = [num(r, key) for r in rows if r.get('tag') == 'drift-start']
        e = [num(r, key) for r in rows if r.get('tag') == 'drift-end']
        if not rows:
            continue
        first = [r for r in rows if r.get('tag') == 'matrix']
        if not s and first:
            # p2quiet and p3 have no drift-start: use the first matrix launch
            # of the same configuration.
            if name == 'dev-p3.txt':
                s = [num(r, key) for r in first if r.get('mode') == 'novm'][:1]
            else:
                s = [num(r, key) for r in first if r.get('cfg') == 'stw'][:1]
        ms, me = med(s), med(e)
        print('| `%s` | %s | %s | %s | %s | %s |' % (name, label, f(ms), f(me), f(me / ms, 2) if ms and me else '-',
                                                    thermal_counts(rows)))
    cd = parse('dev-cooldown.txt')
    if cd:
        print('\nCool-down probes: %d launches, thermal at line ends: %s' % (len(cd), thermal_counts(cd)))


def hello():
    rows = parse('dev-hello.txt')
    if not rows:
        return
    print('\n### Energy readout check (`dev-hello.txt`)\n')
    print('| launch | idle s: ri_energy_nj mJ | busy s: ri_energy_nj mJ | busy ri_penergy_nj mJ | idle ri_billed_energy mJ | busy ri_billed_energy mJ | busy CPU ms | busy P GHz |')
    print('|--:|--:|--:|--:|--:|--:|--:|--:|')
    for r in rows:
        print('| %s | %s | %s | %s | %s | %s | %s | %s |' % (r.get('run'), r.get('idle_energy_mj'), r.get('busy_energy_mj'),
              r.get('busy_penergy_mj'), r.get('idle_billed_mj'), r.get('busy_billed_mj'), r.get('busy_cpu_ms'), r.get('p_ghz')))


def unplugged():
    rows = parse('device-unplugged.txt')
    rows = [r for r in rows if r.get('tag') == 'unplugged' and r.get('kernel')]
    if not rows:
        print('\n### Unplugged cross-check: no lines (see RESULTS.md)\n')
        return
    print('\n### Unplugged cross-check (one process, sequence repeated)\n')
    for r in rows:
        print('- %s %s comp=%s ms=%s energy_mj=%s battery=%s thermal=%s' % (
            r.get('kernel'), r.get('run'), r.get('comp_cfg'), r.get('ms'), r.get('energy_mj'), r.get('battery'),
            r.get('thermal_end')))


if __name__ == '__main__':
    hello()
    part1()
    chase()
    part2()
    part2('dev-p2quiet.txt', 'quiet app, 1 MB/s, 60 s')
    part3()
    drift()
    unplugged()
