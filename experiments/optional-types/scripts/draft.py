#!/usr/bin/env python3
"""Draft side files for kernel classes from their Tonel sources: argument types
from argument names, results from the shape of the body. The draft is then
corrected by hand; `scripts/count.py` compares the two (question 3 and 6).
usage: draft.py <out dir> <Class>...   (reads kernel/ from the repository)"""
import os, re, sys, glob

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../..'))
GENERIC = {'Collection': ['E'], 'SequenceableCollection': ['E'], 'ArrayedCollection': ['E'],
           'Array': ['E'], 'OrderedCollection': ['E'], 'HashedCollection': ['E'], 'Set': ['E'],
           'IdentitySet': ['E'], 'Interval': [], 'Dictionary': ['K', 'V'],
           'IdentityDictionary': ['K', 'V'], 'Association': ['K', 'V'],
           'PositionableStream': ['E'], 'ReadStream': ['E'], 'WriteStream': ['E'],
           'ReadWriteStream': ['E'], 'WeakArray': ['E']}
INT = re.compile(r'^(anInteger|index|anIndex|n|start|stop|size|count|i|j|offset|hi|lo|mid|width|base|capacity|newSize|from|aPriority|milliseconds|limit|aLimit|position)$')

def argtype(name, cls):
    p = GENERIC.get(cls, [])
    if INT.match(name): return 'Integer'
    if name in ('aString', 'aName', 'aPath', 'string', 'separator'): return 'String'
    if name in ('aSymbol', 'aSelector', 'selector'): return 'Symbol'
    if name in ('aCharacter', 'char'): return 'Character'
    if name.endswith('Block') or name == 'aBlock': return '[^Dynamic]'
    if name in ('aNumber', 'aMagnitude', 'min', 'max', 'step'): return 'Number' if name != 'aMagnitude' else 'Magnitude'
    if name in ('aBoolean',): return 'Boolean'
    if name in ('aStream',): return 'WriteStream[Character]'
    if name in ('aClass',): return 'Behavior'
    if name in ('aCollection',): return 'Collection[%s]' % p[0] if p else 'Collection'
    if name in ('anObject', 'value', 'a', 'b', 'c', 'd') and p: return p[-1]
    if name in ('key', 'k') and len(p) == 2: return p[0]
    if name in ('v',) and len(p) == 2: return p[1]
    return 'Object'

def result(sel, body):
    stm = [l.strip() for l in body.strip().split('\n') if l.strip() and not l.strip().startswith('"')]
    rets = [l for l in stm if l.startswith('^')]
    if not rets: return 'Self'
    if all(r.rstrip('.') == '^ self' for r in rets): return 'Self'
    if sel.startswith(('is', 'has', 'includes', 'can', 'not', 'any', 'all', 'none')) or sel in ('=', '<', '>', '<=', '>=', '~=', '==', 'atEnd', 'even', 'odd'): return 'Boolean'
    if sel in ('printString', 'displayString', 'asString', 'storeString', 'name', 'description', 'messageText'): return 'String'
    if sel in ('size', 'hash', 'identityHash', 'basicSize', 'position', 'numArgs', 'asInteger'): return 'Integer'
    if sel in ('asSymbol',): return 'Symbol'
    return 'Dynamic'

def methods(path):
    text = open(path, encoding='utf-8').read()
    for m in re.finditer(r'^(\w+)( class)? >> (.*?) \[\n(.*?)^\]', text, re.M | re.S):
        yield bool(m.group(2)), m.group(3), m.group(4)

def pattern(pat, cls):
    toks = pat.split()
    if len(toks) == 1: return toks[0], 0
    if not toks[0].endswith(':'):
        return '%s <%s>' % (toks[0], argtype(toks[1], cls)), 1
    out = []
    for k, a in zip(toks[0::2], toks[1::2]):
        out.append('%s <%s>' % (k, argtype(a, cls)))
    return ' '.join(out), len(toks) // 2

def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for cls in sys.argv[2:]:
        paths = glob.glob(os.path.join(REPO, 'kernel', '*', cls + '.class.st'))
        assert len(paths) == 1, cls
        p = GENERIC.get(cls, [])
        lines = ['# draft by scripts/draft.py', 'class %s%s' % (cls, '[%s]' % ', '.join(p) if p else '')]
        for meta, pat, body in methods(paths[0]):
            sel = pat.split()[0]
            pt, n = pattern(pat, cls)
            r = result(sel if n == 0 else ''.join(pat.split()[0::2]), body)
            if meta and 'basicNew' in body or (meta and sel.startswith(('new', 'with', 'on'))): r = 'Instance'
            lines.append('%s %s ^<%s>' % ('meta' if meta else 'method', pt, r))
        open(os.path.join(out, cls + '.types'), 'w').write('\n'.join(lines) + '\n')

main()
