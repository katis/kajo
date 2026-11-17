#!/usr/bin/env python3
"""Types 2, part 3 (docs/modules/types-2.md, "The 45"): place the 45
signatures Types 1 left in the side files (inline.py's "not moved" list)
into kernel/, as the owner decided on 2026-11-17 ("Use the Self type where
possible, then do option 3, the form without for a signature without a
method"). The side files and the experiment's checker are not changed.

  place45.py <repo> [--check]

Edits the methods' patterns in place and adds the signatures without a
method at the end of their class files; scripts/canonical-tonel.sh then puts
every entry where the image writes it. With --check nothing is written.
Prints one line per edit and where each of the 45 went, by count:
 1. Self on the method the lookup finds: Number's + - * \\ take and answer
    <Self; Number>, negated and abs answer Self, Magnitude's max: and min:
    take and answer <Self; Magnitude> (Integer's 8 arithmetic, 4 max:/min:
    and 2 negated/abs; Number's max: and min:): 16.
 2. Where Self is wrong the class's own method says so: SmallInteger's and
    LargePositiveInteger's + - * \\ carry <Integer; Number> and their negated
    ^<Integer>; Fraction's + - * answer Number (no signature of the 45 goes
    here: these keep Self from saying what a sum cannot promise).
 3. Object's 15 class-side signatures on Behavior's own methods: 15.
 4. Integer>>// dropped (Number's answers Integer): 1.
 5. Signatures without a method: Integer's bitAnd: bitOr: bitXor:
    bitShift:, SequenceableCollection>>at: and at:put:, Array>>collect:,
    Interval>>select:, Number's < <= > >=, ArrayedCollection class>>new:: 13.
"""
import os, re, sys

repo = sys.argv[1]
check = "--check" in sys.argv
k = os.path.join(repo, "kernel")
files = {}
edits = []
placed = {"1 Self": 0, "3 Behavior": 0, "4 dropped": 0, "5 signature": 0}

def text(rel):
    if rel not in files:
        files[rel] = open(os.path.join(k, rel), encoding="utf-8").read()
    return files[rel]

def retype(rel, old, new, group=None, count=0):
    """Replace one method header line `old` (without the trailing ` [`) by `new`."""
    t = text(rel)
    a, b = old + " [\n", new + " [\n"
    n = t.count("\n" + a)
    assert n == 1, f"{rel}: {old!r} occurs {n} times"
    files[rel] = t.replace("\n" + a, "\n" + b)
    edits.append(f"{rel}: {old}  ->  {new}")
    if group:
        placed[group] += count

def selector(pattern):
    w = pattern.split(" ")
    return "".join(x for x in w if x.endswith(":")) if w[0].endswith(":") else w[0]

def signature(rel, owner, category, pattern):
    t = text(rel)
    for l in open(os.path.join(k, rel), encoding="utf-8").read().split("\n"):
        if l.startswith(owner + " >> "):
            assert selector(l[len(owner) + 4:]) != selector(pattern), f"{rel}: {owner} already has {selector(pattern)}"
    files[rel] = t.rstrip("\n") + f"\n\n{{ #category : {category} }}\n{owner} >> {pattern}\n"
    edits.append(f"{rel}: signature {owner} >> {pattern}")
    placed["5 signature"] += 1

# 1. Self where it says the truth.
N = "Numbers/Number.class.st"
for op in ["*", "+", "-", "\\\\"]:
    # Integer's two signatures of each op (and of \\) go here
    retype(N, f"Number >> {op} aNumber <Number> ^<Number>", f"Number >> {op} aNumber <Self; Number> ^<Self; Number>", "1 Self", 2)
retype(N, "Number >> abs ^<Number>", "Number >> abs ^<Self>", "1 Self", 1)
retype(N, "Number >> negated ^<Number>", "Number >> negated ^<Self>", "1 Self", 1)
M = "Numbers/Magnitude.class.st"
for sel in ["max:", "min:"]:
    # Integer's two and Number's one of each
    retype(M, f"Magnitude >> {sel} aMagnitude <Magnitude> ^<Magnitude>", f"Magnitude >> {sel} aMagnitude <Self; Magnitude> ^<Self; Magnitude>", "1 Self", 3)

# 2. The class's own method where Self is wrong.
for cls, rel in [("SmallInteger", "Numbers/SmallInteger.class.st"), ("LargePositiveInteger", "Numbers/LargePositiveInteger.class.st")]:
    for op in ["*", "+", "-", "\\\\"]:
        retype(rel, f"{cls} >> {op} aNumber", f"{cls} >> {op} aNumber <Integer; Number> ^<Integer; Number>")
    retype(rel, f"{cls} >> negated", f"{cls} >> negated ^<Integer>")
F = "Numbers/Fraction.class.st"
for op in ["*", "+", "-"]:
    retype(F, f"Fraction >> {op} aNumber", f"Fraction >> {op} aNumber <Number> ^<Number>")

# 3. Object's class side on Behavior's own methods.
B = "Classes/Behavior.class.st"
for old, new in [
    ("new", "new ^<Instance>"),
    ("new: size", "new: size <Integer> ^<Instance>"),
    ("basicNew", "basicNew ^<Instance>"),
    ("basicNew: size", "basicNew: size <Integer> ^<Instance>"),
    ("name", "name ^<String>"),
    ("superclass", "superclass ^<Behavior | Nil>"),
    ("selectors", "selectors ^<Array[Symbol]>"),
    ("includesSelector: aSymbol", "includesSelector: aSymbol <Symbol> ^<Boolean>"),
    ("canUnderstand: aSymbol", "canUnderstand: aSymbol <Symbol> ^<Boolean>"),
    ("inheritsFrom: aClass", "inheritsFrom: aClass <Behavior> ^<Boolean>"),
    ("includesBehavior: aClass", "includesBehavior: aClass <Behavior> ^<Boolean>"),
    ("allInstances", "allInstances ^<Array[Instance]>"),
    ("instanceCount", "instanceCount ^<Integer>"),
    ("compiledMethodAt: aSymbol", "compiledMethodAt: aSymbol <Symbol> ^<CompiledMethod>"),
    ("lookupSelector: aSymbol", "lookupSelector: aSymbol <Symbol> ^<CompiledMethod | Nil>"),
]:
    retype(B, f"Behavior >> {old}", f"Behavior >> {new}", "3 Behavior", 1)

# 4. Integer>>// dropped: Number's // answers Integer already.
placed["4 dropped"] += 1
edits.append("Integer>>// dropped (Number >> // aNumber <Number> ^<Integer>)")

# 5. Signatures without a method.
I = "Numbers/Integer.class.st"
for sel in ["bitAnd:", "bitOr:", "bitXor:", "bitShift:"]:
    signature(I, "Integer", "#bits", f"{sel} anInteger <Integer> ^<Integer>")
S = "Collections/SequenceableCollection.class.st"
signature(S, "SequenceableCollection", "#accessing", "at: index <Integer> ^<E>")
signature(S, "SequenceableCollection", "#accessing", "at: index <Integer> put: value <E> ^<E>")
signature("Collections/Array.class.st", "Array", "#accessing", "collect: aBlock <[E, ^:X]> ^<Array[X]>")
signature("Collections/Interval.class.st", "Interval", "#accessing", "select: aBlock <[N, ^Boolean]> ^<Array[N]>")
for sel in ["<", "<=", ">", ">="]:
    signature(N, "Number", "#comparing", f"{sel} aNumber <Number> ^<Boolean>")
signature("Collections/ArrayedCollection.class.st", "ArrayedCollection class", "#accessing", "new: size <Integer> ^<Instance>")

for e in edits:
    print(e)
total = sum(placed.values())
print("placed: " + ", ".join(f"{g}={n}" for g, n in placed.items()) + f", total={total}")
assert total == 45, total
if not check:
    for rel, t in files.items():
        open(os.path.join(k, rel), "w", encoding="utf-8").write(t)
    print(f"written: {len(files)} files")
