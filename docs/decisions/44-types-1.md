# Types 1: the syntax

Briefed by the main session on 2026-11-17 (`docs/modules/types-1.md`, the
owner: "Go ahead", then "start") and built the same day by one build agent
from e28c961: five commits, d5823ca to 85a172a, 58 files. The doc's "Part 1"
and "As built" sections hold every number; the raw files are in
`~/kajo-scratch/types-1/`.

## What was built

Both compilers and both Tonel readers take Strongtalk-style types, keep them
in the parse tree and the source, write them back byte for byte and compile
them to nothing. Nothing is checked yet. No file under the core directories
changed; the class rules and primitives 145 to 147 see names only.

The grammar adds no token:

- A type is a union of members (`T | Nil`); a member is a class name with
  optional arguments (`Array[E]`), a method variable declared by `:` at its
  first appearance (`:X`), a block type (`[A, ^R]`) or a type in parentheses,
  each with an optional `class` after it.
- An argument's type follows its name in the pattern (`collect: aBlock
  <[E, ^:X]>`); the result type is `^<T>` after the pattern.
- Overloads are written by position, a place's alternatives separated by `;`
  (`+ aNumber <Integer; Number> ^<Integer; Number>`).
- In a class definition: `#typeParameters`, `#superclassType`, and a type
  after a name inside `#instVars` (`'array <Array[E | Nil]>'`).
- A type is told from a pragma by the character after `<`: a capital, `[`,
  `(` or `:` starts a type after an argument's name, and is refused where a
  pragma is read ("a pragma name starts with a lowercase letter").
- The `>` that closes a type is one character: the parser splits a binary
  run that starts with `>`, so `^<Integer>| t |` needs no blank.

Class-level types are kept as text in a table of their own (`ClassTypes` in
`Smalltalk`'s `classTypes`), filled by every image build but a release
build. 577 of the experiment's 622 signatures, 15 type parameters, 4
superclass types and 17 instance-variable types moved into 27 kernel files
(`experiments/optional-types/scripts/inline.py`). The tools colour a type in
a pattern and the browser accepts a typed method.

## The brief's starting positions

1. Right: at all 240 pragma places of 2691 methods the `<` is followed by a
   lowercase name.
2. Right, with the one-character `>` in place of the brief's rule.
3. Wrong: a release image keeps every comment and every source (`--release`
   and `kajo seal` only set the header's flag; e28c961's kernel image and
   its release image are both 6 638 864 bytes). So the class-level types
   could not go beside the comment and went into their own table.
4. Right on all 577 typed methods in both compilers: typed, blanked and
   removed compile to the same code.
5. Wrong by a little for typed source only: the typed kernel builds about
   3 percent slower than the same kernel without types, and the kernel's
   compiler takes 1.2 percent longer over it; on untyped source the new
   parser is inside the baseline's spread.

The release image grew 290 976 bytes: 270 048 for the module's own code and
tests (most of it the image build's garbage, the high-water lesson) and
20 928 for the slice's type text in method sources, which a release image
keeps as it keeps every source. The class-level table is 20 960 bytes of the
plain image and nothing in the release image.

## Verified by the main session from the files

- `git log e28c961..HEAD` is the five commits, the tree is clean, and the
  two commits after db78bc3 (the last code commit) touch only the doc. No
  file under `Sources/KajoVM`, `AGENTS.md` or `docs/PLAN.md` changed.
- `~/kajo-scratch/types-1/check/gates.log`: `just check e28c961` on bef504a
  chose the Swift tier, swift.org 6.4.2, seven gates, every one `rc=0`,
  4 333 s; the fuzz line reads `runs=93841 build=ok`.
- `scripts/canonical-tonel.sh --check` run again: lists nothing, rc=0.
- `swift test --filter TypesTests` run again on 85a172a: 4 tests pass
  (`~/kajo-scratch/types-1/verify/types-tests.txt`).
- Read in the raw files: "typed methods 577, differing 0"; the two fuzz
  modes' "libFuzzer build: ok" with 90 837 and 3 763 runs; the sanitizer
  run under load, 12 tests, rc=0; the four broken variants' failing
  outputs; `inline.py`'s counts and its list of the 45.

Not verified by the main session: the timing tables and the image sizes
were read in the doc, not rerun (the agent removed the large scratch
images and kept `part1/sizes.txt`); the development image's 301 tests and
the experiment's 24 were not run again. The Swift tier does not run `just
golden` or the Mac shell's tests mode, which the Smalltalk tier would have;
by the rule of two tiers the higher was owed and they were not run.

## Deviations

- 45 signatures did not move: their class does not define the method
  (Integer's arithmetic with all 6 overloads, Object's class side, Number's
  comparisons, `SequenceableCollection>>at:`). So the overload form is
  built and tested and no kernel method uses it.
- The slice has 6 overloaded selectors, not the brief's 15: the
  experiment's `features.py` cut a line at its first `^`, which can be
  inside a block type.
- `DevelopmentTest>>testRemovedClassesAreFreedAndTheirIndicesTaken` now
  collects garbage first. The new slow test changed the kernel test parts;
  in its new part the test ran after ClassFuzzTest and failed 2 of 2,
  taking the index of a class that test had removed.
- A side-file comment on PositionableStream's `collection` was dropped: a
  comment inside an `#instVars` string is read and not written back.

## Not done

- `kajo seal` keeps the class-level types of the image it seals.
- A class definition in the browser's form has no types.
- Types on temporaries and block parameters (out by the brief).

## Open questions

1. The 45 signatures that restate an inherited method. Recommended: the
   checker's module writes them on the methods that answer them
   (SmallInteger, the large integers, Behavior, Magnitude, Object), and no
   syntax is made for a signature without a method.
2. `kajo seal` and class-level types. Recommended: leave seal as it is; a
   release image is built with `--release`.
3. Types in the browser's class-definition text. Recommended: leave it to
   the module that shows types apart from the text.

The form of overloads (by position with `;`) and of method variables
(`:X`) was the brief's first open question and was built as measured; the
owner has not seen it and can change it while no kernel method uses an
overload.

## 2026-11-17, the owner's answer to question 1

After asking what the 45 were, whether `Self` could help and what option 1
meant: "Use the Self type where possible, then do option 3, the form without
for a signature without a method, design a consistent syntax."

So, for the 45:

1. `Self` on the method the lookup finds, where it says the truth:
   `Number >> + aNumber <Self; Number> ^<Self; Number>` (and `-`, `*`, `\\`),
   `Number >> negated ^<Self>` and `abs`, `Magnitude >> max: aMagnitude
   <Self; Magnitude> ^<Self; Magnitude>` and `min:`. Where `Self` is wrong
   the class's own method says so: SmallInteger and the large integers
   (a sum can change class) carry `<Integer; Number> ^<Integer; Number>`,
   Fraction `^<Number>`.
2. The 15 of `Object class` go on Behavior's own methods (`Behavior >> new
   ^<Instance>`), which is where the lookup ends.
3. `Integer>>//` is dropped: Number's `//` answers Integer already.
4. What is left gets a signature without a method: Integer's `bitAnd:`,
   `bitOr:`, `bitXor:` and `bitShift:` (no method above SmallInteger),
   `SequenceableCollection>>at:` and `at:put:` (Object's method cannot say
   `E`), `Array>>collect:`, `Interval>>select:`, Number's four comparisons
   (the argument narrowed to Number) and `ArrayedCollection class>>new:`.

Not measured: the experiment's checker read the side files, so the count of
diagnostics with `Self` on Number is not known; it is compared with the side
files' 21 before anything relies on it.

## 2026-11-17, the main session's proposal for the form (awaiting the owner)

A signature without a method is a method entry with no body: the same
metadata, the same `Class >> pattern` with its types, and no brackets.

    { #category : #'bit manipulation' }
    Integer >> bitAnd: anInteger <Integer> ^<Integer>

    { #category : #accessing }
    SequenceableCollection >> at: index <Integer> ^<E>

- One grammar: the pattern is the method pattern of this module, so
  overloads (`;`), method variables (`:X`), `Self` and `Instance` are
  written as they are on a method. Nothing new is learned.
- One place: it stands among the class's methods, in the canonical order
  by selector, under its category, on either side (`Foo class >> ...`).
- Told apart by one token: after the pattern a `[` starts a method's body;
  the next entry's `{`, a comment string or the end of the file ends a
  signature; anything else is refused in both readers.
- A class has a method or a signature for a selector, never both: a method
  carries its own types.
- It is nothing to the VM and nothing in a release image: no
  CompiledMethod, no entry in the method dictionary, `respondsTo:`
  unchanged; it is text in the class's `ClassTypes`, with its category,
  which a release build does not fill.
- What it means to the checker: its lookup, upward from the type's class,
  takes the first method or signature it meets.

Open in the proposal: in the browser a method's text has no brackets, so a
pattern alone is today a method with an empty body. Recommended: the kind
is decided by the command ("New signature", shown apart in the selector
list), never by the text. And whether a signature that narrows an inherited
method is checked against it; recommended: yes, in the checker's module.

## 2026-11-17, the owner's answer to the proposal

"Approve". A signature without a method is a method entry with no body, as
proposed. The main session reads the answer as covering the proposal's two
recommendations (in the browser the command decides the kind, never the
text; a signature that narrows an inherited method is checked against it in
the checker's module) and says so to the owner. Still open: `kajo seal` and
the class-level types, types in the browser's class definition, and the
written forms `:X` and `;`, which the approved placement of the 45 uses.
