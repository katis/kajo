# Optional types: the experiment's design brief

## Status

Brief, 2026-11-17. The owner the same day: "I would like to plan an
optional type system for the language. How would that work with live
development, etc." and, after the main session's outline: "Generics are
important, just don't go overboard with the type system. Speed is a good
thing if we can get it, but stuff like documentation, catching errors and
AI feedback is more important. Also as a basis for better auto complete in
the editor for humans. I think we can use the Strongtalk style syntax. You
can experiment with pragmas first if you think it's easier, but Strontalk
for the final build. Diagnostics only."
(`docs/decisions/43-optional-types.md`.)

This is an experiment: evidence, not production code. It changes nothing
under `kernel/`, `tools/` or `Sources/`.

## What is decided

- Types are optional and are diagnostics only. No method is refused, at
  compile time or at run time, for a type. The VM never trusts a type;
  the bytecode verifier and the primitives stay the trust boundary.
- The goals, in the owner's order: documentation, catching errors and
  feedback for an AI agent; a basis for completion in the editor; speed in
  native code only if it comes cheaply (a type as a guarded hint).
- Generics are in. The type system stays small.
- The final syntax is Strongtalk's style (`at: index <Integer> ^<E>`).
  The experiment may carry types any way that is easier.

## What the experiment must answer

1. **How small can the type language be and still say what the kernel
   says?** Candidates, to be cut down, not added to: class types, protocol
   (structural) types, `Self` and `Instance`, the class side, union with
   `Nil`, block types, generic classes with declared parameters (`Array<E>`,
   `Dictionary<K, V>`), generic methods (`collect:` answers a collection of
   the block's result), `Object` as top and an explicit dynamic type for
   "not checked". Name each feature the kernel's collections, streams and
   exceptions cannot be annotated without, and each one they can.
2. **What do generics cost?** Variance (pick the simplest rule that is
   honest: for example invariant parameters with the dynamic type as the
   way out), inference of method type arguments at a send, `Self`-typed
   collections (`select:` answers the receiver's class, `collect:` does
   not always). Try the checker with and without generic methods and say
   what is lost.
3. **How much annotation buys how much checking?** Annotate a slice of
   the kernel (at least the collections' core, streams, String and Symbol,
   Number's tower, Boolean, Object, exceptions and blocks, and one slice
   of `tools/` as a client that is annotated lightly or not at all).
   Report: annotations written, methods checked clean, diagnostics by
   kind, and for a sample of at least 50 diagnostics whether each is a
   real fault, a limit of the type language, or a wrong annotation.
4. **What does an unannotated method get?** The owner's goals need value
   before everything is annotated: local inference from literals, `new`,
   annotated callees and assignments, and the dynamic type elsewhere. Say
   how many sends in the unannotated slice have a known receiver type
   (this is the completion and documentation measure) with 0 annotations
   in that slice.
5. **Is it live?** After one method or one signature changes, recheck
   only what depended on it. Measure the dependents and the recheck time
   for 20 changes spread over leaf methods and widely used signatures
   (`Object>>printOn:`, `Collection>>do:`), in the development image, on
   a background Process. The image is inconsistent between changes by
   design: a diagnostic set, never a failure.
6. **Can the image propose types?** From `allInstances` and the slots'
   actual classes: for the instance variables of the annotated slice,
   what a proposal from live values would say against what a person
   wrote. And from the tests: receiver and argument classes observed at
   run time, if a cheap way exists without changing the VM (if none does,
   say so and stop there).
7. **What would the final syntax need?** Not built: a list of every
   place Strongtalk-style annotations touch (the two compilers that must
   agree, the scanner's `<` against pragmas and binary selectors, the
   Tonel writer and reader and byte identity, class definitions for
   instance variables and type parameters, the syntax fuzzer and the
   compilers' corpus, the source map, `kajo-format` of sources in
   `kernel/`), with the ambiguities found by trying the grammar on paper
   against every method of the kernel (a script may scan for the token
   sequences that would become ambiguous).
8. **What would completion and the protocol need?** Not built: which
   questions a browser, a completion popup and an MCP client would ask
   (the type of this expression, the selectors this receiver answers, the
   diagnostics of this method or class, the dependents of this change)
   and whether the checker's data answers each one at interactive speed.

## How

- The checker is Smalltalk, in a package under
  `experiments/optional-types/` loaded with `kajo build-image --with`,
  working on the kernel compiler's parse tree (`kernel/Compiler/`).
  Nothing in the VM changes; if something seems to need a primitive, say
  so and work around it.
- Annotations do not go into `kernel/` or `tools/`. They live in the
  experiment: a side file per class (selector and signature) or a copy of
  the annotated sources under the experiment's directory. Choose what is
  cheaper and say why.
- Tests for the checker itself (SUnit in the experiment's package): each
  rule with a method that must check and one that must not, and each
  diagnostic kind.
- Prior art is read for the design, not copied: Strongtalk's type system
  (protocols, brands, its generics and what its authors later said they
  would leave out), Bracha's pluggable types, TypeScript's unsound
  choices and why they were made, Sorbet and RBS for Ruby, Typed Racket
  for what soundness costs. `references/MANIFEST.md` lists what is on
  disk; nothing is downloaded.

## The result

`experiments/optional-types/RESULTS.md`: the answers to the eight
questions with numbers and their files, the type language that is
proposed (one page, with what was left out and why), the three or four
decisions the owner must make before a module is briefed, and what the
first module would be.

## Rules of the house that bind here

- Experiment technical details before locking in designs.
- Two implementations of one rule are compared on inputs written for the
  rule's edges (the two compilers, when the syntax comes).
- The primitive is the trust boundary, not the compiler.
- A table that is one object had a hard capacity; module 10 removed it,
  but the checker's tables are measured on the whole image all the same.
- A hand-back answers the question asked; the numbers carry their files.

## Not in this experiment

- Any change to `kernel/`, `tools/`, `Sources/`, the image format or the
  protocol. The final syntax. The tools' display. Native code's use of
  types.
