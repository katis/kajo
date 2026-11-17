# Optional types: the direction

Started by the owner on 2026-11-17: "I think we can table AOT 3 for now. I
would like to plan an optional type system for the language. How would that
work with live development, etc."

## The main session's outline, the same day

Types as diagnostics and never a refusal (Strongtalk's and Newspeak's
position), because a live image is inconsistent between changes; an
incremental checker on a background Process in the development image only;
diagnostics over the development protocol, for the tools and an AI agent;
the image proposing types from live values; the VM never trusting a type,
native code using one only as a guarded hint; protocols and classes, `Nil`
explicit, `Self`, block types; generics as the costly part; the syntax
either Strongtalk's inline form or pragmas; an experiment on the kernel
first.

## 2026-11-17, the owner's decisions

"Generics are important, just don't go overboard with the type system.
Speed is a good thing if we can get it, but stuff like documentation,
catching errors and AI feedback is more important. Also as a basis for
better auto complete in the editor for humans. I think we can use the
Strongtalk style syntax. You can experiment with pragmas first if you think
it's easier, but Strontalk for the final build. Diagnostics only."

1. Diagnostics only.
2. Goals in order: documentation, catching errors, AI feedback; completion
   in the editor; speed if it comes.
3. Generics are in; the type system stays small.
4. Strongtalk-style syntax in the final build; the experiment may carry
   types another way.

The experiment's brief is `experiments/optional-types/DESIGN.md`; its
results will be `experiments/optional-types/RESULTS.md`.

## 2026-11-17, the owner's words while the experiment ran

- On types made from data at run time (an application's scripting
  dictionary as an API): "These generated types would not be stored in the
  serialized source, right?" Answered by the main session and not objected
  to: right, they are derived data and not in the Tonel source; code that
  uses them falls back to the dynamic type when the source of a type is not
  available, and a pinned copy of the dictionary as a data file is optional.
  The experiment got a ninth question from this.
- The owner asked a Fable 5.2 subagent for a type system "fully Smalltalk",
  out of curiosity ("Roles", `~/kajo-scratch/type-ideas/`, not in the
  repository). The answer: "I think the ideas are neat, but a bit too out
  there. Let's proceed with the current trajectory." Not pursued.
- "What about type system bloating the image? Will that be a problem and if
  so, can release build remove it?" The experiment measured it (below).

## 2026-11-17, the experiment's results

`experiments/optional-types/RESULTS.md` (ten commits, 34d14f0 to 1a038bf,
every file under `experiments/optional-types/`; raw outputs in its
`results/`). A checker in Smalltalk, 3 749 lines in 28 classes, loaded as a
package beside the tools; the types of a kernel slice of 27 classes in side
files (622 signatures, 17 variable types); nothing under `kernel/`, `tools/`,
`Sources/`, `scripts/` or `docs/` changed.

Verified by the main session from the files: the commits touch 82 files,
none outside the experiment's directory; the checker's 24 tests pass when
run again (`kajo test ot.img --filter OT`); the numbers below are in
`results/matrix.txt`, `image.txt` and `footprint.txt`; the kernel fault is
there to read (`kernel/Methods/BlockClosure.class.st`, `ifError:`).

Gates: `just check 8218a72` on 1a038bf chose the Swift tier (the diff is
under `experiments/`), swift.org 6.4.2, six gates, every one `rc=0`, 4193 s
(`~/kajo-scratch/optional-types/check/gates.log`).

The nine answers in short:

1. The type language can be small. In: class types by inheritance, generic
   classes with invariant arguments, block types, generic method variables,
   `Self`, `Instance`, `T | Nil` and small unions, overloads, `Dynamic`. The
   slice has 21 diagnostics with it; 145 without overloads, 45 without
   narrowing by class tests, 12 with nil in every type. No annotation needed
   a structural protocol, a variance mark, a bound, a bottom type or
   `T - Nil`. A send to a union checked member by member with `Self` types
   `ifNotNil:` by signatures alone; flow narrowing stays for nil tests in
   zero-argument blocks (19 reads).
2. Generics cost about 60 lines of the checker for method variables;
   invariant arguments cost nothing the kernel shows. Without generic
   methods, sends with a known result fall from 1500 to 1413.
3. The first writing gave 71 diagnostics on the image, all classified: 1
   real fault, 5 faults tests make on purpose, 21 wrong annotations (3.4
   percent of the signatures), the rest limits and the checker's own
   samples. As it stands 654 of the slice's 672 methods are clean and the
   image has 37 diagnostics in 3040 methods.
4. Code with no annotation (243 methods of the tools) has a known receiver
   for 40 percent of its sends with the kernel's types, 31 percent with
   none.
5. It is live. The whole image is checked in 1.3 s; a changed method body
   rechecks 1 method in under 1 ms; a changed signature rechecks 6 to 579
   methods in 0.9 to 555 ms on a background Process.
6. Proposals from live values need a running application (122 of 141
   instance variables had no instance headless) and are narrower than what
   people write. Argument classes traced through the tests found no
   annotation too narrow.
7. The final syntax, on paper: both Tonel readers end a method's pattern at
   the first `[`, so `Array[E]` and block types in a pattern need both
   readers and the writer changed; "a `<` followed by a capital, `[` or `(`
   is a type" separates types from pragmas over the whole kernel; the `|` of
   a union inside temporaries is parsed as part of the type.
8. Completion's questions answer in 2 µs to 5.7 ms where the receiver's type
   is known. The protocol would need `types.at`, `types.selectors`,
   `diagnostics`, `dependents` and a diagnostics event.
9. A scripting dictionary written as a literal became protocols in 78 µs
   and workspace code was checked against them; replacing the dictionary
   rechecked what read it. This needs named protocol types made by code and
   nothing structural in written annotations.

The image's size: the checker's package adds 89 KB of methods and 110 KB of
source; with the slice checked it holds about 1.2 MB, of which 349 KB are
type objects and the rest caches that can be dropped at a save. The whole
kernel annotated is extrapolated, not measured, at 2 to 4 MB in a
development image of 8 MB. A release image built without the checker holds
no type object, on two conditions for the final design: types are not
pragmas (they would be literals in every method) and class-level types are
not class metadata.

Found in the kernel, not fixed: `BlockClosure>>ifError:` sends `receiver`
to every Error and only MessageNotUnderstood answers it, so `[1 / 0]
ifError: [...]` raises a second error inside the handler. Nothing in the
kernel, the tools or the shells' Smalltalk sends `ifError:`.

Deviations: the grammar was scanned by a script, not tried by hand; the
measurements ran headless in an image built with the tools, not in a shell;
the 21 wrong annotations and four faults of the checker were fixed before
the numbers "as it stands" (the first run is kept in `results/first/`).

Not done: a lightly annotated client; a check that an override keeps its
superclass's signature; rounding a proposal up to the class that declares
the protocol used; a run in the shells or on a device. Not explained: the
image file grows 1.2 MB with a package of 0.2 MB.

## Open questions

1. `Nil` explicit (`T | Nil`) or nil in every type. Recommended: explicit,
   with the flow rules; it costs 9 diagnostics on the slice, every one a
   limit, and says which values can be nil.
2. Overloads, several signatures for one selector, first fit. Recommended:
   in; without them Integer arithmetic is typed as Number.
3. Narrowing by class tests for a fixed list of the kernel's testers, no
   predicates declared by users. Recommended: in.
4. Where a class's type parameters and its instance variables' types live.
   Recommended: new keys in the Tonel class definition, kept as text and
   never as class metadata, decided with the syntax module. The other way is
   a side file per class.
5. Protocol types. Recommended: made by code only, none written in
   annotations until one is needed.

The first module would be "Types 1": both compilers and both Tonel readers
take the Strongtalk-style types and write them back byte for byte, the
checker moves to `tools/` and runs on a background Process, diagnostics go
out over the development protocol, and the slice's signatures move inline.
