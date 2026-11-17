#!/usr/bin/env python3
"""Question 1: how often each feature of the type language is used by the side
files (annotations/*.types). usage: features.py [annotations dir]"""
import os, re, sys, glob
from collections import Counter
d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'annotations')
c = Counter(); classes_with_params = []
for f in sorted(glob.glob(os.path.join(d, '*.types'))):
    sels = Counter()
    for line in open(f):
        line = re.sub(r'"[^"]*"', '', line).strip()
        if not line or line.startswith('#'): continue
        word = line.split()[0]
        c['lines ' + word] += 1
        if word == 'class' and '[' in line: classes_with_params.append(line.split()[1])
        if word == 'super': c['super lines (superclass arguments)'] += 1
        if word not in ('method', 'meta', 'ivar', 'cvar'): continue
        types = re.findall(r'<((?:[^<>]|<[^<>]*>)*)>', line)
        if word in ('method', 'meta'):
            pat = re.sub(r'<(?:[^<>]|<[^<>]*>)*>', '', line.split(None, 1)[1].split('^')[0])
            sels[(word, ''.join(t for t in pat.split()))] += 1
        names = set()
        for t in types:
            if '[' in re.sub(r'^\[.*\]$', '', t) and re.search(r'\w\[', t): c['uses a generic class with arguments'] += 1
            if re.search(r'(^|[ ,(|])\[', t): c['uses a block type'] += 1
            if re.search(r'\|\s*Nil\b', t): c['uses T | Nil'] += 1
            if '|' in t.replace('| Nil', '').replace('|Nil', ''): c['uses a union of classes'] += 1
            if re.search(r'\bSelf\b(?! class)', t): c['uses Self'] += 1
            if 'Self class' in t: c['uses Self class'] += 1
            if re.search(r'\bInstance\b(?!\[)', t): c['uses Instance'] += 1
            if 'Instance[' in t: c['uses Instance[...]'] += 1
            if re.search(r'\b[A-Z][A-Z0-9]?\b class', t): c['uses X class (a variable\'s class)'] += 1
            if re.search(r'\b\w+ class\b', t) and not re.search(r'\b(Self|[A-Z][A-Z0-9]?) class', t): c['uses a class-side type (Foo class)'] += 1
            if 'Dynamic' in t: c['uses Dynamic'] += 1
            for v in re.findall(r'\b([A-Z][A-Z0-9]?)\b', t): names.add(v)
        params = set()
        if names - {'E', 'K', 'V', 'C', 'N'}: c['generic method signatures (own variables)'] += 1
    c['overloaded selectors'] += sum(1 for k, v in sels.items() if v > 1)
for k in sorted(c): print('%s: %d' % (k, c[k]))
print('generic classes: ' + ' '.join(classes_with_params))
