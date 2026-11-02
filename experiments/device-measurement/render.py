#!/usr/bin/env python3
"""Fill RESULTS.tmpl.md's {{heading}} markers with the matching sections of
bench-output.txt (report.py's output) and write RESULTS.md."""
import re

out = open('bench-output.txt').read().split('\n')


def section(key):
    for i, l in enumerate(out):
        if l.startswith('#') and key in l:
            level = len(l) - len(l.lstrip('#'))
            whole = key.startswith('Part C')
            body = []
            for m in out[i + 1:]:
                if m.startswith('#'):
                    lv = len(m) - len(m.lstrip('#'))
                    if not whole or lv <= level:
                        break
                    m = '####' + m.lstrip('#')
                body.append(m)
            title = l.lstrip('#').strip()
            return '### ' + title + '\n' + '\n'.join(body).rstrip()
    raise SystemExit('no section ' + key)


t = open('RESULTS.tmpl.md').read()
t = re.sub(r'\{\{(.+?)\}\}', lambda m: section(m.group(1)), t)
open('RESULTS.md', 'w').write(t)
