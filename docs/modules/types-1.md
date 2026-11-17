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
