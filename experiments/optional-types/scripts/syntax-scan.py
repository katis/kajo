#!/usr/bin/env python3
"""Question 7: where Strongtalk-style annotations would sit in the kernel's and
the tools' methods, and which token sequences there would become ambiguous.
Reads every Tonel file under kernel/ and tools/; prints counts, one per line.
usage: syntax-scan.py [repo]"""
import os, re, sys, glob
from collections import Counter

repo = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(os.path.join(os.path.dirname(__file__), '../../..'))
files = sorted(glob.glob(os.path.join(repo, 'kernel', '**', '*.st'), recursive=True) +
               glob.glob(os.path.join(repo, 'tools', '**', '*.st'), recursive=True))
c = Counter()
pragma_names = Counter()
METHOD = re.compile(r'^(\w+)( class)? >> (.*?) \[\n?(.*?)^\]', re.M | re.S)

def strip(s):
    # remove comments and string literals (keeping their lengths irrelevant)
    s = re.sub(r'"[^"]*"', ' ', s)
    s = re.sub(r"'(?:[^']|'')*'", "''", s)
    s = re.sub(r"\$.", "$x", s)
    return s

for f in files:
    text = open(f, encoding='utf-8').read()
    c['files'] += 1
    m = re.search(r"#instVars : \[(.*?)\]", text, re.S)
    if m: c['instance variable declarations'] += len(re.findall(r"'(\w+)'", m.group(1)))
    for mm in METHOD.finditer(text):
        pat, body = mm.group(3), strip(mm.group(4))
        c['methods'] += 1
        toks = pat.split()
        nargs = len(toks) // 2
        c['argument positions (a <T> after each)'] += nargs
        c['result positions (^<T> after the pattern)'] += 1
        if toks and not toks[0][0].isalpha():
            c['binary patterns'] += 1
            if '<' in toks[0] or '>' in toks[0]:
                c['binary patterns whose selector holds < or > (e.g. < aMagnitude <Magnitude>)'] += 1
        b = body.lstrip()
        # pragmas at the method's start, before or after the temporaries
        prag = re.findall(r'<\s*([A-Za-z]\w*:?)', re.split(r'\n\s*[^\s<|]', '\n' + b, maxsplit=1)[0])
        for p in prag:
            pragma_names[p] += 1
        if prag:
            c['methods with pragmas'] += 1
            if nargs:
                c['methods with arguments and pragmas (an argument type <T> next to <pragma>)'] += 1
        if b.startswith('|'):
            c['methods with temporaries (| t <T> | would hold a | of a union)'] += 1
        c['block literals with arguments ([:x <T> | ...])'] += len(re.findall(r'\[\s*:', body))
        c['blocks with temporaries ([:x | | t <T> | ...])'] += len(re.findall(r'\[\s*(?::\w+\s*)+\|\s*\|\s*\w[\w\s]*\|', body)) + len(re.findall(r'\[\s*\|\s*\w[\w\s]*\|', body))
        if '[' in pat:
            c['patterns with [ already (comments)'] += 1
        # expressions where a < is followed by a capitalized name and a > (would read as a type if casts were allowed)
        c['body sequences < Name > (a cast would collide with comparisons)'] += len(re.findall(r'<\s*[A-Z]\w*\s*>', body))
        c['body sequences ^< or ^ <'] += len(re.findall(r'\^\s*<', body))
        c["body sequences ||"] += body.count('||')

for k in sorted(c): print('%s: %d' % (k, c[k]))
print('pragma names: ' + ', '.join('%s %d' % kv for kv in pragma_names.most_common()))
print('pragma names starting with a capital: %d' % sum(v for k, v in pragma_names.items() if k[0].isupper()))
