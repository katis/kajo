# Types 1: the syntax

## Status

Brief, written 2026-11-17 by the main session. The owner on 2026-11-17, on
the optional type system: "Generics are important, just don't go overboard
with the type system. [...] I think we can use the Strongtalk style syntax.
[...] Diagnostics only." On the experiment's five questions the same day:
"Accept, fix ifError". On this brief: "Go ahead". The record is
`docs/decisions/43-optional-types.md`; the experiment is
`experiments/optional-types/RESULTS.md`.

The experiment named a first module that held the syntax, the checker's
move to `tools/` and the diagnostics over the protocol. This brief is the
syntax alone (the main session's cut, a step at a time). The checker in the
development image is the module after it.

## What it is

Both compilers and both Tonel readers take Strongtalk-style types in a
method's pattern and in a class definition, keep them in the parse tree and
in the recorded source, write them back byte for byte, and compile them to
nothing. The types of the experiment's kernel slice move from its side files
into `kernel/`. Nothing checks a type in this module, and nothing in the VM
knows that types exist.

## What is known

Check these before building on them. All are from the experiment (1a038bf)
unless a commit is named.

- The slice: 27 classes, 622 signatures, 17 variable types, in
  `experiments/optional-types/annotations/*.types` (format in its README).
  The notation inside `<...>` there is the one the final syntax would use.
- `experiments/optional-types/scripts/syntax-scan.py` over `kernel/` and
  `tools/` (208 files, 2658 methods): 223 methods have a pragma, 0 pragma
  names start with a capital; 87 binary patterns, 28 with `<` or `>` in the
  selector; `^<` appears 0 times in a method body.
- Both Tonel readers end a method's pattern at the first `[`: `Tonel.swift`
  in `Sources/KajoCompiler/` and `TonelReader` in the kernel, with the
  writer's `Scanner class>>patternEndIn:`. A typed pattern holds `Array[E]`
  and `[E, ^R]`.
- The experiment's checker (`experiments/optional-types/OptionalTypes/`)
  reads types from the side files with the kernel's own `Scanner`. Its type
  parser is the nearest thing to a grammar that has run.
- The two compilers are compared method for method by `CompilerTest`, by
  the corpus (`Tests/KajoCompilerTests/Fixtures/compiler-corpus/corpus.txt`)
  and by the syntax fuzzer's kernel mode (`scripts/fuzz.sh syntax-kernel`).
- `scripts/canonical-tonel.sh --check` asserts that `kernel/` and `tools/`
  are byte for byte what the image writes.
- Bytecodes are compared in their plain form (primitive 166,
  `CompiledMethod>>plainBytecodes`).

## The type language

Decided by the owner (`43-optional-types.md`); this module gives it a
grammar and nothing more.

- A class name: `Integer`. A generic class with arguments: `Array[E]`,
  `Dictionary[K, V]`.
- A block type: `[A, B, ^R]`, `[^R]`.
- A union: `T | Nil`, `A | B`.
- `Self`, `Self class`, `X class`, `Instance`, `Instance[X]`, `Dynamic`,
  `Nil`.
- A generic method variable, declared where it first appears.
- Several signatures for one selector (overloads), first fit.

Where a type is written:

- after each argument of a method's pattern and after the pattern as its
  result: `at: index <Integer> put: value <E> ^<E>`, `size ^<Integer>`,
  `+ aNumber <Number> ^<Number>`;
- in a class definition: the class's type parameters, what it gives its
  superclass's parameters (`super Foo[T]` in the side files), and a type
  for an instance variable.

Not written anywhere in this module: types on temporaries, on block
parameters and on block temporaries (the experiment's flow inference typed
them; open question 2).

## Starting positions

To be measured in part 1. Say where one is wrong.

1. "A `<` followed by a capital, `[` or `(` is a type, anything else is a
   pragma" separates the two in every method of `kernel/`, `tools/` and
   `apps/Shared/smalltalk`, and in every entry of the corpus.
2. A binary selector's scan never swallows the `<` of a type or the `>`
   that ends one, with the rule "a type never ends in `>>` or `>|`", or
   with a better one the scan suggests.
3. The image holds a class's comment and tag today, and holds a method's
   source in a per-class sources table. Find where, and find what a release
   image (`kajo build-image --release`, `kajo seal`) keeps of each. The
   class-level types must be in a development image for the byte-identical
   write and must be absent from a release image; this position decides how
   (open question 3).
4. A typed method and the same method with its types removed compile to
   equal plain bytecodes, equal literals and an equal pc-to-source map up to
   the shift of offsets, in both compilers. This is true by construction
   only if no type reaches code generation; show it on the 622.
5. Compiling the kernel is not slower with types in the parser than
   without, outside the spread of five runs of the image build and of
   `Compiler` compiling every method in the image.

## Parts

1. **Measure and decide, build nothing else.** Run starting positions 1, 2,
   3 and 5's baseline. Write the grammar as a text in this doc: tokens, the
   type grammar, the places, and the rule that tells a type from a pragma.
   Settle open question 1 (how overloads and method variables are written)
   by writing all 15 overloaded selectors and the 49 generic signatures of
   the slice in each candidate form. Commit the grammar and the choice with
   their reasons before part 2.
2. **The bootstrap compiler** (`Sources/KajoCompiler/Syntax.swift`): the
   scanner and parser take the grammar, `MethodNode` keeps the types with
   their source ranges, code generation never sees them. A capitalized
   pragma name is refused.
3. **The kernel's compiler** (`kernel/Compiler/`): the same grammar, the
   same refusals with the same reasons, `MethodNode` keeps the types.
   `Scanner class>>patternEndIn:` skips a type with its brackets.
4. **Tonel**: both readers and the writer; a typed pattern and the
   class-level keys round-trip byte for byte. The class rules and the
   define and redefine paths carry the class-level types as part 1 decided.
5. **The slice moves inline.** A script turns the 27 side files into edits
   of `kernel/` (the script is kept under the experiment's `scripts/`); the
   result is in the canonical form. The experiment's side files stay as
   they are; its checker is not changed.
6. **The tools, the least that keeps them right**: `SourceColorer` colours
   a type as a type and not as a pragma or a send; the browser's method
   pane accepts and shows a typed method (a tools test that compiles one
   through `DevClient`). No new window, no completion, no diagnostics.

## Tests

Before the code where possible.

- A table of patterns for each place and each form of the type grammar,
  run through both parsers, asserting the types kept and their ranges.
- Refusals at the edges, the same reason from both compilers: an unclosed
  type, a type after the result, two result types, a capitalized pragma, a
  type list ending in `>>`, nesting past the parser's limit (the limit is
  measured on the smallest stack, as AGENTS.md says for recursion).
- The corpus gains typed entries at and past each limit; the syntax fuzzer
  gains typed seeds in both modes.
- Starting position 4 as a test over every typed method of the image.
- The Tonel round trip of every typed class file, byte identity.
- A release image built from the typed kernel: no type text and no
  class-level type data in it, checked on the image's bytes for a marker
  type name that appears nowhere else.
- Broken variants, each failing a named check: a type that reaches the
  literal frame; a reader that ends the pattern at the first `[`; the
  pragma rule without the capital test; the kernel's parser accepting what
  the bootstrap refuses.

## The bar

- Every method of `kernel/` and `tools/` compiles to the plain bytecodes it
  had on the starting commit; the typed ones too.
- `CompilerTest` passes: the two compilers agree on every method, typed or
  not.
- `scripts/canonical-tonel.sh --check` lists nothing.
- The kernel's tests, the tools' tests and the experiment's 24 tests pass
  (the experiment's on an image built as its RESULTS.md says).
- A release image of the typed kernel is the same size as one of the
  starting commit's kernel, up to what part 1 found a release image keeps
  of sources; say the bytes.
- Compile time inside the baseline's spread (starting position 5).
- `just check <starting commit>` on the final code commit, whatever tier it
  chooses; if the class-level types touch `Sources/KajoVM/Loader` or
  `ObjectModel`, that is the core tier with the device rows.
- The syntax fuzzer in both modes, with its "libFuzzer build: ok" line.

## Rules of the house that bind here

- A refusal is a value at a boundary that takes Smalltalk's input: a
  malformed type is a CompileError with a line, never a trap.
- An operand or count is checked where it is encoded; a recursion limit is
  measured.
- Two implementations of one rule are compared on inputs written for the
  rule's edges. When they disagree, ask which one the trust boundary agrees
  with.
- An invariant the loader checks binds every live change: if a class gains
  data in the image, read the loader's rules and the snapshot fuzzer's
  seeds first.
- The primitive is the trust boundary, not the compiler: nothing a type
  says may change what the make primitive or the verifier accepts.
- A syntax change is checked against every reader of source.
- What a release image must not hold is decided by where it is stored.

## Not in this module

- Checking anything. The experiment's checker stays in `experiments/`.
- The development protocol, completion, the browser showing types apart
  from the source text.
- Types on temporaries, block parameters and block temporaries.
- Native code or the interpreter reading a type.
- Annotating more of the kernel than the experiment's slice.

## Deliverables

The code and tests above; this doc with an "As built" section (the grammar,
each starting position's answer, the numbers with their files, gates,
deviations, not done, found); work files in `~/kajo-scratch/types-1/`.

## Open questions

Build the recommended option; decisions only.

1. How overloads and method variables are written inline. Constraints: no
   literal in the method, no clash with pragmas or temporaries, readable in
   a browser, and both Tonel readers find the pattern's end. Recommended:
   whichever candidate part 1 shows shortest over the slice's 15 and 49
   that meets the constraints; Strongtalk's `def` at a variable's first use
   is the candidate for method variables.
2. Types on block parameters and temporaries. Recommended: not in the
   grammar now; the experiment needed none, and the `|` of a union inside
   `| ... |` is the hardest part of the grammar.
3. Where a development image keeps the class-level types. Recommended:
   beside the class's comment, wherever that is, if a release image drops
   it; a table of the development package otherwise. Never a slot of the
   class.
4. The name of the top-level keys in a class definition. Recommended:
   `#typeParameters` and `#superclassType`, and a type written after an
   instance variable's name inside its `#instVars` string
   (`'array <Array[E | Nil]>'`), so one list still names every variable.

## Part 1: measured and decided (2026-11-17, e28c961)

Measured on the mini with swiftly's swift.org 6.4.2 first on PATH. Raw files
in `~/kajo-scratch/types-1/part1/`, scripts in `~/kajo-scratch/types-1/scripts/`
(`scan.py`, `q1.py`, `timing.sh`, `coverage.py`). Nothing was built.

### The starting positions

1. **Right.** `scan.py` tokenizes every method source as the bootstrap
   scanner does: 2691 methods of `kernel/`, `tools/` and
   `apps/Shared/smalltalk` and the corpus's 154 entries (one has no
   pattern). The parser reads pragmas at 240 places in them; at all 240 the
   `<` is followed by a lowercase keyword (193) or a lowercase identifier
   (47); none by a capital, `[`, `(` or `:` (`part1/scan.txt`). No body has
   `^` followed by `<`. Five bodies have `<` followed by `(` (comparisons,
   `c * 3 < (n * 4)`), never at a pragma position; types are read only in
   the pattern, so they do not matter. The rule grows by one character for
   method variables (below): a `<` followed by a capital, `[`, `(` or `:`.
2. **Right, with a better rule than the brief's.** 87 binary patterns, 28
   with `<` or `>` in the selector (`-> < << <= > >= >>`); in each the
   selector is followed by the argument's name, so a type's `<` is never
   next to the selector. The 30 tokens in bodies that start with `>>` or
   `>|` are sends (`Foo >> #bar`), never in a pattern. The one place a
   binary run can swallow part of a type is after its closing `>`
   (`^<Integer>| t |`, `<A><B>`, `<A>>`). The rule built: **the `>` that
   closes a type is one character.** When the parser expects it and the
   token is a binary run starting with `>`, it takes the `>` and scans the
   rest again. So a type may end in `>>`, `>|` or `><` without a blank,
   and what follows the `>` is read as if a blank were there (`<A>>` is
   then a type followed by a stray `>`, refused as any stray `>` is). Both
   compilers do the same; a test writes each of the slice's signatures with
   the blanks around `>` removed.
3. **A release image keeps every comment and every source.** The comment
   is `ClassDefinition>>comment`, one per class in `Smalltalk`'s
   `definitions` table (handed over by `recordDefinitions:`); a method's
   source is in `Smalltalk`'s `sources`, one `IdentityDictionary` per class
   (`recordSources:`). `kajo build-image --release` and `kajo seal` only set
   the image header's release flag (`Image.seal`, `KernelBuild`): the
   starting commit's kernel image and its release image are both
   6 638 864 bytes, and a comment's text and a method's source are found in
   both (`grep -c` 2 and 2, `part1/sp3.txt`). So the comment's place cannot
   hold the class-level types (question 3 below).
4. Measured in part 2 (a test over every typed method).
5. **The baseline** (aligned release build of e28c961, five runs,
   `part1/timing-baseline.txt`): the image build 113 to 123 ms (its own
   ms); `CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid` (the
   kernel's Compiler compiling every method of the image and comparing)
   1 025 to 1 043 ms.

Where the brief was wrong: the slice has **6** overloaded selectors (12
signatures), not 15. `features.py` cuts a line at its first `^`, inside a
block type, so `ifTrue:` and `ifTrue:ifFalse:` (and seven more pairs) had one
key. And 45 of the 622 signatures cannot move inline as they are: their class
does not define the method (Integer's arithmetic, all 6 overloads among them,
is SmallInteger's and the large integers'; Object's 15 class-side signatures
are Behavior's instance methods; `SequenceableCollection>>at:` is Object's).
A signature written inline needs a method to be written in, and a method
added for it would change what runs. 577 move (526 instance side, 51 class
side; `coverage.py`); the 45 are listed in part 5's output and stay in the
side files (an open question for the checker's module).

### Open question 1: how overloads and method variables are written

`q1.py` writes the 49 generic signatures (56 method variables) and the 6
overloaded selectors in each candidate form (`part1/q1.txt`, every signature
in every form). Characters of the typed patterns:

| method variables | 49 signatures | over implicit |
|---|---|---|
| implicit (a one- or two-letter name that is not a class parameter: the side files' rule) | 2 431 | 0 |
| Strongtalk's `X def` at the first appearance | 2 655 | +224 |
| `:X` at the first appearance (the mark of a block's argument) | 2 487 | +56 |

| overloads (the 6, 12 signatures) | characters | example |
|---|---|---|
| the typed pattern repeated, one per line | 380 | `+ aNumber <Integer> ^<Integer>` / `+ aNumber <Number> ^<Number>` |
| alternatives: each further signature's types after the first one's result | 307 | `+ aNumber <Integer> ^<Integer> <Number> ^<Number>` |
| positions: each place lists its type per signature, separated by `;` | 289 | `+ aNumber <Integer; Number> ^<Integer; Number>` |

Implicit variables are shortest but are not declared, which the type
language asks for, and rest on a convention no parser can check. The
repeated pattern is longest and needs two tokens of lookahead to tell
`< aMagnitude <M...` from a pragma. Chosen, as the brief recommends (the
shortest that meets the constraints):

- **A method variable is declared by `:` at its first appearance**
  (`collect: aBlock <[E, ^:X]> ^<Collection[X]>`, `inject: initial <:A>
  into: aBlock <[A, E, ^A]> ^<A>`). No literal, no clash: `:` never follows
  a pragma's `<`, and it reads as a block argument's declaration does.
- **Overloads are written by position**: a place's alternatives separated
  by `;`, the k-th of each place being signature k (`+ aNumber <Integer;
  Number> ^<Integer; Number>`). A place with one type has it in every
  signature, an untyped place is Dynamic in every one, and places with
  alternatives all have the same number of them. Each argument keeps its
  types beside it. No literal, no clash (`;` is not in the union's or a
  block type's syntax), and the pattern still ends where the parser ends it.
  A unary method has no overloads.

### The grammar

No new token. A type is read from the tokens the scanner already makes:
identifiers, `<`, `>` (the first character of a binary token, see starting
position 2), `[`, `]`, `(`, `)`, `,`, `|`, `^`, `:` and `;`.

    type         = member { "|" member }                 a union
    member       = primary [ "class" ]                   X class, Self class
    primary      = Name [ "[" type { "," type } "]" ]    a class, a generic class with arguments
                 | ":" Name                              a method variable, declared here
                 | "[" [ type { "," type } "," ] "^" type "]"   a block type: [A, B, ^R], [^R]
                 | "(" type ")"
    Name         = an identifier whose first character is A to Z
                   (Self, Instance, Dynamic and Nil are names like any other)
    alternatives = type { ";" type }                     one per signature (overloads)

The places, in a method's pattern only:

    pattern      = identifier [ result ]
                 | binarySelector identifier [ argType ] [ result ]
                 | keyword identifier [ argType ] { keyword identifier [ argType ] } [ result ]
    argType      = "<" alternatives ">"
    result       = "^" "<" alternatives ">"

and in a class definition (question 4):

    #typeParameters : [ 'E', ... ]        Names, no two alike
    #superclassType : 'Name[...]'         a type whose name is the #superclass's
    #instVars : [ 'name <type>', ... ]    each item: { identifier [ "<" type ">" ] }

A class-level type holds no `:` and no `;`. Types on temporaries, block
arguments and block temporaries are not in the grammar (question 2).

**The rule that tells a type from a pragma**: after an argument's name, a `<`
followed by a capital, `[`, `(` or `:` starts the argument's type; after the
pattern, `^` followed by `<` starts the result type; anywhere the parser reads
pragmas, a `<` followed by a capital, `[`, `(` or `:` is refused ("a pragma
name starts with a lowercase letter"), so a pragma's name never starts with a
capital. Anything else is as before.

**Nesting**: every `[`, `(` and generic argument list inside a type counts
against the parser's depth limit of 32, as blocks and parentheses do; the
limit is measured for types on a 512 KB thread in part 2.

**What is kept**: the method's tree keeps each argument's type and the result
type, each with its source range (byte offsets of the text between the angle
brackets), and each type's parts with theirs. Code generation reads none of
it. A method's recorded source is its text, types included, so the Tonel
writer writes them back where they were.

### Question 3: where a development image keeps the class-level types

The comment's place is kept by a release image, so the brief's second
option: **a table of its own**, `Smalltalk`'s `classTypes` (class to its type
parameters, superclass type and instance variable types, as text), filled by
the image build of a development or kernel image and by the definition paths
in the image. The release build (`kajo build-image --release`, the one a
generated app's Release configuration runs) hands no types over, and a release
image cannot define or redefine a class (InstallForbidden), so a release image
holds the table's one nil slot and no type data. `kajo seal` of an image that
holds types keeps them, as it keeps that image's comments, sources and tools
(an open question). Never a slot of the class, never in the VM: the class
rules and primitives 145 to 147 see names only.

### Question 4: the keys

`#typeParameters` and `#superclassType`, written after `#superclass`, and a
type after an instance variable's name inside its `#instVars` string, one
blank between (`'array <Array[E | Nil]>'`). The writer writes each only when
present; a reader takes a comment inside an `#instVars` string as the
scanner does (skipped) and the writer leaves it out.
