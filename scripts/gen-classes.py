#!/usr/bin/env python3
"""Module 9c: a package of generated classes for the browser's measurements
(docs/modules/developer-ui.md, Measurements): N classes in a tree (each
class's superclass one of the earlier ones), M methods each, in categories,
as Tonel files in the canonical form. Usage: gen-classes.py <dir> <classes> <methods>"""
import os, sys

out, n, m = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "package.st"), "w") as f:
    f.write("Package { #name : #Generated }\n")
for i in range(n):
    name = "Gen%04d" % i
    sup = "Object" if i < 20 else "Gen%04d" % ((i * 7919) % i)
    cats = {}
    for j in range(m):
        cats.setdefault("cat%d" % (j % 4), []).append(j)
    body = []
    for c in sorted(cats):
        for j in sorted(cats[c], key=lambda j: "m%02d%s" % (j, "" if j % 3 else ":")):
            sel = "m%02d" % j
            if j % 3 == 0:
                pat, src = sel + ": x", "^ x + %d" % j
            else:
                pat, src = sel, "^ %d" % (i * m + j)
            body.append((c, pat, src))
    body.sort(key=lambda t: (t[0], t[1].split(":")[0] + (":" if ":" in t[1] else "")))
    s = '"A generated class (module 9c\'s browser measurement)."\nClass {\n\t#name : #%s,\n\t#superclass : #%s,\n\t#category : #\'Generated-%d\'\n}\n' % (name, sup, i % 50)
    for c, pat, src in body:
        s += "\n{ #category : #%s }\n%s >> %s [\n\t%s\n]\n" % (c, name, pat, src)
    with open(os.path.join(out, name + ".class.st"), "w") as f:
        f.write(s)
