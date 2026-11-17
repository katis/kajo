#!/usr/bin/env python3
"""Types 1, part 5: move the slice's types from the side files
(annotations/*.types) into kernel/, in the inline syntax of
docs/modules/types-1.md. The side files stay as they are.

- A method signature goes into the pattern of the method its class defines
  on that side: a type after each argument's name, `^<R>` after the pattern.
  A method variable (a name of one or two characters that is not a parameter
  of the class's `class` line, the side files' rule) is declared with `:` at
  its first appearance.
- A signature whose class does not define the method (it restates an
  inherited one) cannot be written inline and is listed, not moved.
- `class Name[P, Q]` becomes `#typeParameters`, `super T` becomes
  `#superclassType`, `ivar name <T>` a type after the name in `#instVars`.
  A side file's comment is left out.

The result is written in the canonical form the image writes (checked by
scripts/canonical-tonel.sh --check afterwards). Refuses a kernel that has
types already. usage: inline.py [repo] [--dry-run]"""
import glob, os, re, sys
from collections import Counter

args = [a for a in sys.argv[1:] if not a.startswith('--')]
repo = args[0] if args else os.path.abspath(os.path.join(os.path.dirname(__file__), '../../..'))
dry = '--dry-run' in sys.argv
ann = os.path.join(repo, 'experiments/optional-types/annotations')
TYPE = r'<((?:[^<>])*)>'

kernel_files = {os.path.basename(f)[:-9]: f for f in glob.glob(os.path.join(repo, 'kernel/**/*.class.st'), recursive=True)}

def strip_comment(line):
    out, depth, q = '', 0, False
    for ch in line:
        if ch == '"' and depth == 0: q = not q; continue
        if q: continue
        if ch == '<': depth += 1
        if ch == '>': depth -= 1
        out += ch
    return out.strip()

def parse_sig(rest):
    types = []
    def take(m): types.append(m.group(1)); return '\x00'
    skel = re.sub(TYPE, take, rest)
    result = None
    if '^\x00' in skel:
        result = types.pop()
        skel = skel.replace('^\x00', '').strip()
    parts = [t for t in skel.split() if t != '\x00']
    sel = ''.join(parts) if parts[0].endswith(':') else parts[0]
    return sel, parts, types, result

def mark_variables(texts, params):
    """The texts with each method variable declared by : at its first appearance."""
    seen, out = set(), []
    for t in texts:
        if t is None: out.append(None); continue
        def sub(m):
            v = m.group(1)
            if v in params or v in seen: return v
            seen.add(v)
            return ':' + v
        out.append(re.sub(r'(?<![\w:])([A-Z][A-Z0-9]?)\b', sub, t))
    return out

c = Counter()
not_moved = []
for f in sorted(glob.glob(os.path.join(ann, '*.types'))):
    cls = os.path.basename(f)[:-6]
    path = kernel_files[cls]
    text = open(path, encoding='utf-8').read()
    if '#typeParameters' in text or '#superclassType' in text or re.search(r'^\w+( class)? >> .*<[A-Z\[(:].* \[$', text, re.M):
        sys.exit('%s has types already' % path)
    params, superType, ivars, sigs = [], None, [], []
    for line in open(f, encoding='utf-8'):
        line = line.strip()
        if not line or line.startswith('#'): continue
        line = strip_comment(line)
        word, rest = line.split(None, 1)
        if word == 'class':
            m = re.match(r'(\w+)(?:\[(.*)\])?$', rest)
            assert m.group(1) == cls, f
            params = [p.strip() for p in m.group(2).split(',')] if m.group(2) else []
        elif word == 'super':
            superType = rest
        elif word == 'ivar':
            m = re.match(r'(\w+)\s+<(.*)>$', rest)
            ivars.append((m.group(1), m.group(2)))
        elif word == 'cvar':
            sys.exit('cvar lines are not moved: ' + line)
        elif word in ('method', 'meta'):
            sigs.append((word == 'meta',) + parse_sig(rest))
    # the class definition
    if params or superType or ivars:
        head_end = text.index('\n}\n')
        head = text[:head_end]
        lines = head.split('\n')
        k = next(i for i, l in enumerate(lines) if l.startswith('\t#superclass : '))
        if not lines[k].endswith(','): lines[k] += ','
        ins = []
        if params:
            ins.append('\t#typeParameters : [')
            ins += ['\t\t%r%s' % (p, ',' if i < len(params) - 1 else '') for i, p in enumerate(params)]
            ins.append('\t],' )
            c['type parameters'] += len(params)
        if superType:
            ins.append("\t#superclassType : '%s'," % superType)
            c['superclass types'] += 1
        lines[k + 1:k + 1] = ins
        head = '\n'.join(lines)
        if head.endswith(','): head = head[:-1]
        for name, ty in ivars:
            n = head.count("\t\t'%s'" % name)
            assert n == 1, (cls, name, n)
            head = head.replace("\t\t'%s'" % name, "\t\t'%s <%s>'" % (name, ty))
            c['instance variable types'] += 1
        text = head + text[head_end:]
    # the methods
    for meta, sel, parts, types, result in sigs:
        side = ' class' if meta else ''
        pat_re = re.compile(r'^' + re.escape(cls + side) + r' >> (.*?) \[$', re.M)
        hits = []
        for m in pat_re.finditer(text):
            toks = m.group(1).split()
            s = ''.join(toks[0::2]) if toks[0].endswith(':') else toks[0]
            if s == sel: hits.append(m)
        if not hits:
            not_moved.append('%s%s>>%s' % (cls, side, sel))
            c['signatures not moved (the class does not define the method)'] += 1
            continue
        assert len(hits) == 1, (cls, sel)
        m = hits[0]
        toks = m.group(1).split()
        marked = mark_variables(list(types) + [result], params)
        argtypes, res = marked[:-1], marked[-1]
        if toks[0].endswith(':'):
            kws, names = toks[0::2], toks[1::2]
            assert len(kws) == len(argtypes), (cls, sel)
            pat = ' '.join('%s %s <%s>' % (k, n, t) for k, n, t in zip(kws, names, argtypes))
        elif len(toks) == 2:
            assert len(argtypes) == 1, (cls, sel)
            pat = '%s %s <%s>' % (toks[0], toks[1], argtypes[0])
        else:
            assert not argtypes, (cls, sel)
            pat = toks[0]
        if res is not None: pat += ' ^<%s>' % res
        text = text[:m.start(1)] + pat + text[m.end(1):]
        c['signatures moved'] += 1
        c['method variables declared'] += sum(t.count(':') for t in marked if t)
    if not dry:
        open(path, 'w', encoding='utf-8').write(text)
for k in sorted(c): print('%s: %d' % (k, c[k]))
print('not moved (%d): %s' % (len(not_moved), ' '.join(not_moved)))
