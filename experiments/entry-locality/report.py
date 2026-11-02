#!/usr/bin/env python3
"""Tables for RESULTS.md from results/*.txt (bench.sh and bench-device.sh).
Usage: report.py results/   Medians over runs; thermal states counted for
the phone. Every table names the file it came from."""
import os
import sys
from collections import defaultdict
from statistics import median

D = sys.argv[1] if len(sys.argv) > 1 else 'results'


def parse(name, drift=False):
    """Rows of a results file; drift runs (tag=drift-*) only if `drift`."""
    rows = []
    try:
        f = open(os.path.join(D, name))
    except OSError:
        return rows
    for line in f:
        if line.startswith('#') or '=' not in line or 'FAILED' in line:
            continue
        d = {}
        for tok in line.split():
            if '=' in tok:
                k, v = tok.split('=', 1)
                d.setdefault(k, v)
        if not drift and d.get('tag', '').startswith('drift'):
            continue
        rows.append(d)
    return rows


def num(d, k, default=None):
    try:
        return float(d[k])
    except (KeyError, ValueError):
        return default


def f(x, d=1):
    if x is None:
        return '-'
    return ('%.' + str(d) + 'f') % x


def thermal(rows):
    c = defaultdict(int)
    for r in rows:
        for k in ('thermal_start', 'thermal_end'):
            if k in r:
                c[r[k]] += 1
    return ', '.join('%s %d' % kv for kv in sorted(c.items())) if c else ''


# ---------------------------------------------------------------- Part 1

MODES = ['chase', 'dsep', 'dlocal', 'dhalf']


def part1(name, label):
    rows = parse(name)
    if not rows:
        return
    g = defaultdict(list)
    for r in rows:
        g[(r['mode'], int(r['size_mb']), int(r['threads']))].append(num(r, 'ns_hop'))
    med = {k: median(v) for k, v in g.items()}
    threads = sorted({k[2] for k in med})
    sizes = sorted({k[1] for k in med if k[0] != 'spread'})
    runs = max(len(v) for v in g.values())
    th = thermal(rows)
    for t in threads:
        print('\n### Part 1, %s, %d thread%s: ns per hop (median of %d runs)%s\n'
              % (label, t, '' if t == 1 else 's', runs, (' [thermal: %s]' % th) if th else ''))
        print('Size = chase node array (N x 64 B) per thread; dsep and dlocal touch 1.25x that, dhalf 0.75x.\n')
        print('| size MB | chase | dsep | dlocal | dhalf | dsep/chase | dlocal/chase | dhalf/chase | dlocal/dsep |')
        print('|--:|--:|--:|--:|--:|--:|--:|--:|--:|')
        for s in sizes:
            m = {mo: med.get((mo, s, t)) for mo in MODES}
            if m['chase'] is None:
                continue
            r = lambda a, b: f(a / b, 2) if a and b else '-'
            print('| %d | %s | %s | %s | %s | %s | %s | %s | %s |' % (
                s, f(m['chase']), f(m['dsep']), f(m['dlocal']), f(m['dhalf']),
                r(m['dsep'], m['chase']), r(m['dlocal'], m['chase']), r(m['dhalf'], m['chase']),
                r(m['dlocal'], m['dsep'])))
        ss = sorted({k[1] for k in med if k[0] == 'spread' and k[2] == t})
        if ss:
            print('\n%s, %d thread%s, spread (one 64-byte node per 16 KiB page): ns per hop against the page footprint\n'
                  % (label, t, '' if t == 1 else 's'))
            print('| page footprint MB | pages | node bytes KB | spread ns/hop | minus spread at the smallest size |')
            print('|--:|--:|--:|--:|--:|')
            base = med[('spread', ss[0], t)]
            for s in ss:
                v = med[('spread', s, t)]
                pages = s * 64
                print('| %d | %d | %d | %s | %s |' % (s, pages, pages * 64 // 1024, f(v), f(v - base)))


# ---------------------------------------------------------------- Part 3

def kgroup(rows):
    g = defaultdict(list)
    for r in rows:
        g[(r['variant'], r['kernel'], int(r['workers']))].append(r)
    return g


def medf(rs, k):
    v = [num(r, k) for r in rs if num(r, k) is not None]
    return median(v) if v else None


def checksums(g, kernel, variants, w=1):
    s = set()
    for v in variants:
        for r in g.get((v, kernel, w), []):
            s.add(r.get('checksum'))
    return 'yes' if len(s) == 1 else ('NO %s' % sorted(s))


def hop(name, label, variants='ABCL', sizes=(20, 21, 22, 23)):
    rows = parse(name)
    if not rows:
        return
    g = kgroup(rows)
    print('\n### Per-hop cost, %s (`%s`), 1 worker, medians%s\n' % (label, name,
          (' [thermal: %s]' % thermal(rows)) if thermal(rows) else ''))
    print('Per hop = (walkN - walkbuildN) / (2 x 2^N) ns. A-bytes = 24 B x 2^N.\n')
    hdr = '| N | A-MB | ' + ' | '.join('%s ns/hop' % v for v in variants) + ' | ' + \
        ' | '.join('%s/A' % v for v in variants if v != 'A') + ' | L/B | checksums equal |'
    print(hdr)
    print('|' + '--:|' * (hdr.count('|') - 2) + ':-:|')
    for n in sizes:
        ph = {}
        for v in variants:
            w = medf(g.get((v, 'walk%d' % n, 1), []), 'ms')
            b = medf(g.get((v, 'walkbuild%d' % n, 1), []), 'ms')
            ph[v] = (w - b) * 1e6 / (2 * 2 ** n) if w is not None and b is not None else None
        if all(x is None for x in ph.values()):
            continue
        r = lambda a, b: f(a / b, 2) if a and b else '-'
        print('| %d | %d | %s | %s | %s | %s |' % (
            n, 24 * 2 ** n >> 20, ' | '.join(f(ph[v]) for v in variants),
            ' | '.join(r(ph[v], ph['A']) for v in variants if v != 'A'), r(ph.get('L'), ph.get('B')),
            checksums(g, 'walk%d' % n, variants)))
    print('\nWhole kernel (walkN ms), build (walkbuildN ms), footprint (MB: rss_mb on the Mac, phys_footprint peak on the phone):\n')
    print('| N | ' + ' | '.join('%s walk ms' % v for v in variants) + ' | ' +
          ' | '.join('%s build ms' % v for v in variants) + ' | ' + ' | '.join('%s MB' % v for v in variants) + ' |')
    print('|' + '--:|' * (1 + 3 * len(variants)))
    for n in sizes:
        cells = []
        for k in ('walk%d' % n, 'walkbuild%d' % n):
            cells += [f(medf(g.get((v, k, 1), []), 'ms')) for v in variants]
        fp = []
        for v in variants:
            rs = g.get((v, 'walk%d' % n, 1), [])
            x = medf(rs, 'footprint_peak_mb')
            fp.append(f(x if x is not None else medf(rs, 'rss_mb'), 0))
        if all(c == '-' for c in cells):
            continue
        print('| %d | %s | %s |' % (n, ' | '.join(cells), ' | '.join(fp)))
    if any(v == 'L' for v in variants):
        print('\nL locality after walkN (entries whose body is in the same block):\n')
        print('| N | entries used | local fraction | small blocks | large blocks |')
        print('|--:|--:|--:|--:|--:|')
        for n in sizes:
            rs = g.get(('L', 'walk%d' % n, 1), [])
            if rs:
                print('| %d | %.0f | %s | %.0f | %.0f |' % (n, medf(rs, 'entries_used'), f(medf(rs, 'local_frac'), 4),
                                                         medf(rs, 'small_blocks'), medf(rs, 'large_blocks')))


def orig(name, label):
    rows = parse(name)
    if not rows:
        return
    g = kgroup(rows)
    print('\n### Cross-check: object-representation\'s own walk/walkbuild (2^22, lib Big), %s, 1 worker\n' % label)
    print('| variant | walk ms | walkbuild ms | ns/hop |')
    print('|---|--:|--:|--:|')
    for v in 'ABC':
        w = medf(g.get((v, 'walk', 1), []), 'ms')
        b = medf(g.get((v, 'walkbuild', 1), []), 'ms')
        if w is None:
            continue
        print('| %s | %s | %s | %s |' % (v, f(w), f(b), f((w - b) * 1e6 / (2 * 2 ** 22)) if b else '-'))


def compact(name, label, hopname, variants='ABL'):
    rows = parse(name)
    if not rows:
        return
    g = kgroup(rows)
    hg = kgroup(parse(hopname))
    print('\n### Walk after compaction, %s (`%s`), 1 worker, medians%s\n' % (label, name,
          (' [thermal: %s]' % thermal(rows)) if thermal(rows) else ''))
    print('Per hop after compaction = (walkcompactN - walkcompactbuildN) / (2 x 2^N); "fresh" = the walkN per-hop from the hop table.\n')
    print('| N | variant | per hop after compaction | fresh per hop | after/fresh | after / A after | L/B after | compaction pause ms | moved MB | L bodies moved off their entry block | L local fraction after |')
    print('|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|')
    for n in (22, 23):
        res = {}
        for v in variants:
            w = medf(g.get((v, 'walkcompact%d' % n, 1), []), 'ms')
            b = medf(g.get((v, 'walkcompactbuild%d' % n, 1), []), 'ms')
            hw = medf(hg.get((v, 'walk%d' % n, 1), []), 'ms')
            hb = medf(hg.get((v, 'walkbuild%d' % n, 1), []), 'ms')
            res[v] = ((w - b) * 1e6 / (2 * 2 ** n) if w is not None and b is not None else None,
                      (hw - hb) * 1e6 / (2 * 2 ** n) if hw is not None and hb is not None else None)
        for v in variants:
            a, fr = res[v]
            if a is None:
                continue
            rs = g.get((v, 'walkcompactbuild%d' % n, 1), [])
            nl = medf(rs, 'compact_nonlocal')
            lv = medf(rs, 'compact_live')
            print('| %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (
                n, v, f(a), f(fr), f(a / fr, 2) if fr else '-',
                f(a / res['A'][0], 2) if res.get('A', (None,))[0] else '-',
                f(a / res['B'][0], 2) if v == 'L' and res.get('B', (None,))[0] else '',
                f(medf(rs, 'compactStw_ms')), f((medf(rs, 'compactBytesMoved') or 0) / 2 ** 20, 0),
                ('%.0f of %.0f' % (nl, lv)) if v == 'L' and nl is not None else '',
                f(medf(rs, 'local_frac'), 4) if v == 'L' else ''))
    print('\nchecksums equal across variants: ' + ', '.join(
        'N=%d %s' % (n, checksums(g, 'walkcompact%d' % n, variants)) for n in (22, 23)))


def mark(name, label, variants='ABL'):
    rows = parse(name)
    if not rows:
        return
    g = kgroup(rows)
    print('\n### Mark rate, %s (`%s`): stop-the-world mark of the walk graph, one thread%s\n' % (
        label, name, (' [thermal: %s]' % thermal(rows)) if thermal(rows) else ''))
    print('| N | variant | live MB | mark ms | MB/s | /A | sweep ms | worker QoS |')
    print('|--:|---|--:|--:|--:|--:|--:|---|')
    for n in (22, 23):
        base = None
        for v in variants:
            rs = g.get((v, 'walkmark%d' % n, 1), [])
            if not rs:
                continue
            ms = medf(rs, 'gc1Mark_ms')
            live = medf(rs, 'liveBytes') / 2 ** 20
            rate = live / (ms / 1000)
            if v == 'A':
                base = ms
            qos = sorted({r.get('worker_qos', '?') for r in rs})
            print('| %d | %s | %.0f | %s | %.0f | %s | %s | %s |' % (n, v, live, f(ms), rate,
                  f(ms / base, 2) if base else '-', f(medf(rs, 'gc1Sweep_ms')), ','.join(qos)))


def sends(name, label, workers=(1, 6), variants='ABL'):
    rows = parse(name)
    if not rows:
        return
    g = kgroup(rows)
    print('\n### sends and ivars, %s (`%s`), medians%s\n' % (label, name,
          (' [thermal: %s]' % thermal(rows)) if thermal(rows) else ''))
    print('| kernel | workers | A ms | B ms | L ms | B/A | L/A | L/B | checksums equal |')
    print('|---|--:|--:|--:|--:|--:|--:|--:|:-:|')
    for k in ('sends', 'ivars'):
        for w in workers:
            m = {v: medf(g.get((v, k, w), []), 'ms') for v in variants}
            if m['A'] is None:
                continue
            r = lambda a, b: f(a / b, 2) if a and b else '-'
            print('| %s | %d | %s | %s | %s | %s | %s | %s | %s |' % (k, w, f(m['A']), f(m['B']), f(m['L']),
                  r(m['B'], m['A']), r(m['L'], m['A']), r(m['L'], m['B']), checksums(g, k, variants, w)))


def work(name, label):
    rows = parse(name)
    if not rows:
        return
    g = defaultdict(list)
    for r in rows:
        g[(r['mode'], int(r['size_mb']), int(r.get('work', 0)))].append(num(r, 'ns_hop'))
    med = {k: median(v) for k, v in g.items()}
    works = sorted({k[2] for k in med})
    print('\n### Chase with independent work per hop, %s (`%s`), 1 thread, ns per hop (median)%s\n' % (
        label, name, (' [thermal: %s]' % thermal(rows)) if thermal(rows) else ''))
    print('work = multiply-adds per hop on a register the chain does not depend on (64 = about 55 ns of core time).\n')
    cols = [(m, w) for w in works for m in ('chase', 'dsep', 'dlocal')]
    print('| size MB | ' + ' | '.join('%s w=%d' % c for c in cols) + ' | ' +
          ' | '.join('dsep/chase w=%d' % w for w in works) + ' | ' + ' | '.join('dlocal/dsep w=%d' % w for w in works) + ' |')
    print('|' + '--:|' * (1 + len(cols) + 2 * len(works)))
    for sz in sorted({k[1] for k in med}):
        cells = [f(med.get((m, sz, w))) for (m, w) in cols]
        r = lambda a, b: f(a / b, 2) if a and b else '-'
        cells += [r(med.get(('dsep', sz, w)), med.get(('chase', sz, w))) for w in works]
        cells += [r(med.get(('dlocal', sz, w)), med.get(('dsep', sz, w))) for w in works]
        print('| %d | %s |' % (sz, ' | '.join(cells)))


def membw(name, label):
    rows = parse(name)
    if not rows:
        return
    vm = defaultdict(list)
    ch = defaultdict(list)
    for r in rows:
        st = int(r.get('stream_mb', 0))
        if 'variant' in r:
            vm[(r['variant'], r['kernel'], st)].append(r)
        else:
            ch[(r['mode'], int(r['size_mb']), st)].append(r)
    th = thermal(rows)
    print('\n### Companion bandwidth, %s (`%s`): alone vs with a thread streaming through 64 MB, medians%s\n' % (
        label, name, (' [thermal: %s]' % th) if th else ''))
    sts = sorted({k[2] for k in vm} | {k[2] for k in ch})
    print('| what | ' + ' | '.join('stream %d MB' % s for s in sts) + ' | with/alone | companion MB/s | P-core GHz alone, with |')
    print('|---|' + '--:|' * (len(sts) + 3))
    for n in (21, 22):
        for v in 'ABL':
            ph = []
            for st in sts:
                w = medf(vm.get((v, 'walk%d' % n, st), []), 'ms')
                b = medf(vm.get((v, 'walkbuild%d' % n, st), []), 'ms')
                ph.append((w - b) * 1e6 / (2 * 2 ** n) if w is not None and b is not None else None)
            if ph[0] is None:
                continue
            bw = medf(vm.get((v, 'walk%d' % n, sts[-1]), []), 'stream_mbs')
            gh = [f(medf(vm.get((v, 'walk%d' % n, st), []), 'p_ghz'), 2) for st in sts]
            print('| %s walk%d ns/hop | %s | %s | %s | %s |' % (v, n, ' | '.join(f(x) for x in ph),
                  f(ph[-1] / ph[0], 2) if ph[0] and ph[-1] else '-', f(bw, 0), ', '.join(gh)))
    for sz in sorted({k[1] for k in ch}):
        for m in ('chase', 'dsep', 'dlocal'):
            vals = [medf(ch.get((m, sz, st), []), 'ns_hop') for st in sts]
            if vals[0] is None:
                continue
            bw = medf(ch.get((m, sz, sts[-1]), []), 'stream_mbs')
            gh = [f(medf(ch.get((m, sz, st), []), 'p_ghz'), 2) for st in sts]
            print('| %s %d MB ns/hop | %s | %s | %s | %s |' % (m, sz, ' | '.join(f(x) for x in vals),
                  f(vals[-1] / vals[0], 2) if vals[0] and vals[-1] else '-', f(bw, 0), ', '.join(gh)))


def membw2(name, label):
    rows = parse(name)
    if not rows:
        return
    g = defaultdict(list)
    for r in rows:
        rate = int(r.get('stream_rate', -1)) if 'stream_mb' in r else 0
        key = r['variant'] + ' ' + r['kernel'] if 'variant' in r else '%s %s MB' % (r['mode'], r['size_mb'])
        g[(key, rate)].append(r)
    rates = sorted({k[1] for k in g})
    th = thermal(rows)
    print('\n### Companion rate, %s (`%s`): per hop against the companion\'s capped bandwidth, medians%s\n' % (
        label, name, (' [thermal: %s]' % th) if th else ''))
    print('Columns: companion off, then capped at N MB/s (1 = the companion thread only spins). Achieved companion MB/s in brackets.\n')
    print('| ns/hop | ' + ' | '.join('off' if r == 0 else '%d MB/s' % r for r in rates) + ' |')
    print('|---|' + '--:|' * len(rates))
    for v in 'ABL':
        cells = []
        for r in rates:
            w = medf(g.get((v + ' walk22', r), []), 'ms')
            b = medf(g.get((v + ' walkbuild22', r), []), 'ms')
            bw = medf(g.get((v + ' walk22', r), []), 'stream_mbs')
            cells.append((f((w - b) * 1e6 / (2 * 2 ** 22)) if w is not None and b is not None else '-') +
                         (' [%s]' % f(bw, 0) if bw else ''))
        print('| %s walk22 | %s |' % (v, ' | '.join(cells)))
    for m in ('chase', 'dsep'):
        cells = []
        for r in rates:
            x = medf(g.get(('%s 256 MB' % m, r), []), 'ns_hop')
            bw = medf(g.get(('%s 256 MB' % m, r), []), 'stream_mbs')
            cells.append(f(x) + (' [%s]' % f(bw, 0) if bw else ''))
        print('| %s 256 MB | %s |' % (m, ' | '.join(cells)))


def lcg(name, label):
    rows = parse(name)
    if not rows:
        return
    g = defaultdict(list)
    for r in rows:
        g[(r['mode'], int(r['size_mb']), r.get('order', 'random'))].append(num(r, 'ns_hop'))
    print('\n### Visiting order, %s (`%s`): random cycle vs the walk kernel\'s LCG order, ns per hop (median)%s\n' % (
        label, name, (' [thermal: %s]' % thermal(rows)) if thermal(rows) else ''))
    print('| size MB | mode | random | lcg | lcg/random |')
    print('|--:|---|--:|--:|--:|')
    for sz in sorted({k[1] for k in g}):
        for m in ('chase', 'dsep', 'dlocal'):
            a = g.get((m, sz, 'random')); b = g.get((m, sz, 'lcg'))
            if not a or not b:
                continue
            print('| %d | %s | %s | %s | %s |' % (sz, m, f(median(a)), f(median(b)), f(median(b) / median(a), 2)))


def qos(name, label):
    rows = parse(name)
    if not rows:
        return
    g = defaultdict(list)
    for r in rows:
        g[(r['variant'], r['kernel'], r.get('worker_qos', '?'))].append(r)
    print('\n### Worker QoS check, %s (`%s`): walk22 per hop, workers at user-initiated vs default attributes%s\n' % (
        label, name, (' [thermal: %s]' % thermal(rows)) if thermal(rows) else ''))
    print('| variant | worker QoS | walk22 ms | walkbuild22 ms | ns/hop |')
    print('|---|---|--:|--:|--:|')
    for v in 'AB':
        for q in sorted({k[2] for k in g}):
            w = medf(g.get((v, 'walk22', q), []), 'ms')
            b = medf(g.get((v, 'walkbuild22', q), []), 'ms')
            if w is None or b is None:
                continue
            print('| %s | %s | %s | %s | %s |' % (v, q, f(w), f(b), f((w - b) * 1e6 / (2 * 2 ** 22))))


def drift(name, label):
    rows = parse(name, drift=True)
    if not rows:
        return
    first = [r for r in rows if r.get('tag') == 'drift-start']
    last = [r for r in rows if r.get('tag') == 'drift-end']
    if not first or not last:
        return
    key = 'ns_hop' if 'ns_hop' in first[0] else 'ms'
    a, b = medf(first, key), medf(last, key)
    print('- %s: first kernel repeated at the end: %s -> %s %s (x%s); thermal over the file: %s' % (
        label, f(a, 2), f(b, 2), key, f(b / a, 3), thermal(rows)))


if __name__ == '__main__':
    print('# entry-locality: tables (generated by report.py from results/)')
    part1('mac-part1.txt', 'Mac (M2 Max)')
    part1('dev-part1.txt', 'iPhone 17 Pro')
    hop('mac-hop.txt', 'Mac')
    hop('dev-hop.txt', 'iPhone')
    orig('mac-orig.txt', 'Mac')
    orig('dev-orig.txt', 'iPhone')
    compact('mac-compact.txt', 'Mac', 'mac-hop.txt')
    compact('dev-compact.txt', 'iPhone', 'dev-hop.txt')
    mark('mac-mark.txt', 'Mac')
    mark('dev-mark.txt', 'iPhone')
    sends('mac-sends.txt', 'Mac')
    sends('dev-sends.txt', 'iPhone')
    membw('mac-membw.txt', 'Mac')
    membw('dev-membw.txt', 'iPhone')
    membw2('dev-membw2.txt', 'iPhone')
    lcg('mac-lcg.txt', 'Mac')
    lcg('dev-lcg.txt', 'iPhone')
    work('mac-work.txt', 'Mac')
    work('dev-work.txt', 'iPhone')
    qos('mac-qos.txt', 'Mac')
    qos('dev-qos.txt', 'iPhone')
    print('\n### Thermal drift (phone)\n')
    for n in ('dev-part1.txt', 'dev-hop.txt', 'dev-compact.txt', 'dev-mark.txt', 'dev-sends.txt'):
        drift(n, n)
