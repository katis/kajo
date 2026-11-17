# Results: an optional type system for Kajo

Run 2026-11-17 on the Mac mini (M2 Pro) from commit 8218a72 onwards, with
swiftly's swift.org toolchain 6.4.2 first on PATH (`swift build -c release
--product kajo`). Every number below names the file it comes from;
`results/` holds the raw outputs, `scripts/run.sh all` makes them again
(work files in `~/kajo-scratch/optional-types/`). Nothing under `kernel/`,
`tools/`, `Sources/`, `scripts/` or `docs/` changed.

## What was built

- **The checker** (`OptionalTypes/`, 3 749 lines of Smalltalk in 28
  classes and one extension, tests included) is a package loaded with `kajo build-image --with tools --with
  experiments/optional-types/OptionalTypes`. It works on the kernel
  compiler's `Parser` tree, never refuses a method, and gives diagnostics:
  `dnu`, `maybeNil`, `argType`, `arity`, `blockResult`, `returnType`,
  `assignType`, `annotation` and `parse`. It keeps a dependency index (from a
  signature, an inferred method body, a selector looked up, a protocol, to
  the methods whose check read it) so that a change rechecks only those
  methods. Switches let one run compare variants of the language
  (`OTChecker` class comment).
- **The annotations are side files**, one per class
  (`annotations/<Class>.types`, format in `annotations/README.md`), in the
  notation the final syntax would use inside `<...>`: `at: <Integer> put:
  <E> ^<E>`. Side files were cheaper than a copy of the sources. A copy
  would have had to stay equal to `kernel/` as it changes. A side file is
  read by the kernel's own `Scanner`, and adding or removing a type is a
  one-line diff. RBS does the same for Ruby. The cost: a side file cannot
  type temporaries, and it must name every selector again.
- **The tests**: 24 SUnit tests (`OTCheckerTest`, `OTScriptingTest`, with
  `OTSample` as the methods they check). Each rule has a method that must
  check clean and one that must not. Each diagnostic kind and each switch
  has a test. Run: `kajo test ot.img --filter OT`: **24 tests, 24 passed**.
  The kernel's own tests on a kernel image with the package give 273 of 273
  (249 kernel + 24). The kernel image alone gives 249 of 249. The development
  image with the package gives 319 of 319 (295 + 24).
- **The measurements** (`OTMeasure`) run with `kajo run ot.img --sources
  <dir>`. An extension `UndefinedObject>>run:of:` in the package reads
  `<dir>/command` and writes `<dir>/out/*.txt`.

The slice that was annotated: Object, UndefinedObject, Boolean,
BlockClosure, Magnitude, Number, Integer, Float, Fraction, Character,
Collection, SequenceableCollection, ArrayedCollection, Array,
OrderedCollection, HashedCollection, Set, Dictionary, Interval, Association,
String, Symbol, PositionableStream, ReadStream, WriteStream, Exception and
Error. That is 27 side files, 670 lines, 622 signatures and 17 variable
types (`results/slice.txt`, `results/features.txt`). The client slice of
`tools/` (BrowserModel, DebuggerModel, InspectorModel, TargetPickerModel,
TestRunnerModel, ToolModel, TranscriptModel, WorkspaceModel, DevClient and
SourceColorer: 243 methods, 1440 sends) has **no annotations**.

## Things found in the kernel

- **A real fault: `BlockClosure>>ifError:`.** It sends `receiver` to every
  `Error`, and only `MessageNotUnderstood` answers `receiver`. So `[1 / 0]
  ifError: [:m :r | ...]` raises a new MessageNotUnderstood from inside the
  handler, and the handler does not catch it. Checker: `dnu
  BlockClosure>>ifError::2 Error does not understand #receiver`
  (`results/image-diagnostics.txt`). Confirmed by running it in a scratch
  image: the outer handler got "ZeroDivide: division by zero does not
  understand #receiver". Not fixed.
- Five diagnostics are in tests that cause the fault on purpose:
  `BlockClosureTest>>testValues` (arity), `ExceptionTest>>testExceptionDescription`,
  `ExceptionTest>>testHandlerSelection`, and `ObjectTest>>testDoesNotUnderstand`
  twice. They are listed as `intended`.
- **A fault in the experiment's own code**, found by running the checker on
  the image that held it. `OTChecker>>invalidate:` used `Set with:`, which
  Kajo's Set does not have. The method had not run yet. It was fixed before
  its first call (commit d43ee4a).

## The answers

### 1. How small can the type language be?

In use, with counts from `results/features.txt` over the 622 signatures:

| feature | uses | could the slice do without it? |
|---|---|---|
| class types (nominal, by inheritance) | most lines | no |
| generic classes with parameters (`Array[E]`, `Dictionary[K, V]`, 12 classes) | 70 types | yes, but the element types are lost (question 2) |
| `super Foo[T]`: what a class gives its superclass's parameters | 4 | no: `Dictionary` is a `HashedCollection[V]`, `String` an `ArrayedCollection[Character]` |
| block types `[A, ^R]` | 99 | no: every iterator, `ifTrue:`, `on:do:` |
| generic method variables (`collect: <[E, ^X]> ^<Collection[X]>`) | 49 signatures | barely (question 2) |
| `T \| Nil` | 16 | yes, if nil may be in every type (the `nilLoose` row, question 1 below) |
| unions of classes | 4 between classes, 13 between a type and a method variable (`at:ifAbsent: ^<V \| X>`) | no for the 13; the 4 could be `Object` |
| `Self` | 129 | no |
| `Instance`, `Instance[X]` (class-side constructors) | 15 + 14 | no: `new`, `with:` |
| `Foo class`, `Self class`, `X class` | 1 + 1 + 1 | `X class` is what types the argument of `on:do:`'s handler; `Self class` types `self class foo` |
| `Dynamic` | 85 | it is the way out |
| overloads (one selector, several signatures, first fit) | 15 selectors | no: see `noOverloads` |
| `Object` as top | yes | no |

The checker's flow rules have no syntax, but they are part of what the
language means. Nil tests narrow a variable in the branch they guard and
after `ifTrue: [^ ...]`. With the `typeTests` switch, class tests do too.
A variable assigned in a block joins its old type, loops and recursive
blocks are typed twice, and a temporary is "unassigned", not Nil, until
assigned.

What the switches cost, on the slice of 672 methods (`results/matrix.txt`):

| row | diagnostics | clean methods | sends with a known result |
|---|---|---|---|
| base (the proposed language) | 21 | 654 | 1500 |
| `noOverloads` (last signature only) | 145 | 598 | 1497 |
| `noTypeTests` (only nil tests narrow) | 45 | 641 | 1461 |
| `nilLoose` (nil belongs to every type) | 12 | 663 | 1500 |
| `covariant` type arguments | 21 | 654 | 1500 |
| `noGenericMethods` | 19 | 656 | 1413 |
| `noGenericClasses` (and no generic methods) | 9 | 665 | 1405 |

What the collections, streams and exceptions cannot be annotated without:
class types, generic classes, block types, `Self`, `Instance[X]`, generic
method variables, `T | Nil` or nil in every type, overloads for arithmetic
(an Integer plus an Integer is an Integer, anything else a Number), `X
class` for handlers, and Dynamic.

What they can be annotated without:
- structural protocols. No annotation needed one. The 21 `limit:type-test`
  diagnostics of the first run (below) were code that tests a class and
  then sends (`aNumber isFraction | aNumber isInteger ifFalse: [...]`),
  and flow narrowing answers them.
- variance annotations: `covariant` changed nothing.
- bounds on parameters. Their absence costs 1 + 5 diagnostics:
  `Collection>>sum`, and inside `Interval[N]`.
- `Self[X]`: `collect:` is stated again in Array, OrderedCollection, Set,
  Dictionary, Interval and String (6 lines).
- a bottom type: `error:` answers Dynamic.
- tuples: a brace array of unrelated classes is `Array[Dynamic]`.
- enumeration types, intersections and `T - Nil`.

Stream elements are left out. Streams are typed by their collection,
`WriteStream[C]`. Their element type would need a bound
(`C <: SequenceableCollection[E]`), so `next` is Dynamic. A text stream's
`collection` instance variable is Dynamic, because it is a String or a
ByteArray.

**The narrowing operator: counts.** The owner asked whether union types
need a narrowing operator. These are the uses in the whole image, with the
proposed language (`results/image.txt`, the "narrowing counts" line; the
checker counts a read of a narrowed union-typed variable once per read):

- (a) A nil test the compiler inlines, narrowing a temporary or argument by
  flow: **29** reads. The checker implements it.
- (b) A block parameter that binds the narrowed value (`ifNotNil: [:v |
  ...]`): **6** sends. The checker implements it.
- (c) A class test narrowing by flow (`isKindOf:`, `isMemberOf:`, `class ==`,
  `isString`, `isSymbol`, `isNumber`, `isInteger`, `isFraction` and the
  like, and `|` or `or:` of them): **38** reads. The checker implements it
  behind `typeTests`, on by default. Off, the slice has 24 more diagnostics.
- (d) Plain polymorphism, where every member answers the message: **23**
  sends to a union of classes. With `memberwiseNil` there are 15 more, to
  `T | Nil`, where Nil answers the message too.
- (e) Nothing in the kernel's idiom works, and Dynamic or an assertion is
  the way out: **10** diagnostics.
  - 8 are `OrderedCollection`'s `array` of `E | Nil`. The slots between
    `firstIndex` and `lastIndex` are never nil, but no type says so.
  - 2 are in `String>>splitOn:`. The value of `x isCharacter ifTrue:
    [x asString] ifFalse: [x]` is a union, but at run time it is always a
    String.

Instance variables never needed narrowing. No read of a narrowed instance
variable was counted. Two `ifNil:`-family sends have an instance variable of
`T | Nil` as receiver, and their block parameter (b) covered them. The
checker narrows instance variables by the same rule as temporaries, but this
is unsound if another Process stores to them meanwhile. User-declared type
predicates (a tester method that narrows) can be left out. The class tests
the kernel uses are the kernel's own testers, and a fixed list of 12
selectors in the checker covered them all
(`OTMethodCheck>>conditionNarrowing:in:`).

**`ifNotNil:` and "T without Nil" with signatures alone.** The main session
proposed that the language needs no subtraction operator. The checker
confirms it, behind the switch `memberwiseNil`. A send to a union is
checked member by member, each member with its own class's signature, and
the results are joined. Nil is a member when UndefinedObject has its own
method for the selector. The signatures (in `annotations/Object.types` and
`annotations/UndefinedObject.types`):

    Object          method ifNotNil: <[Self, ^R]> ^<R>
    Object          method ifNil: <[^R]> ^<Self>
    Object          method ifNil: <[^R]> ifNotNil: <[Self, ^S]> ^<S>
    UndefinedObject method ifNotNil: <Dynamic> ^<Nil>
    UndefinedObject method ifNil: <[^R]> ^<R>
    UndefinedObject method ifNil: <[^R]> ifNotNil: <Dynamic> ^<R>

Checked example (`OTCheckerTest>>testIfNotNilBySignaturesAlone`), with the
instance variable `name <String | Nil>`:
- `name ifNotNil: [:n | n asUppercase]` answers `String | Nil`. The block's
  parameter is String.
- `name ifNotNil: [:n | n zork]` gives `String does not understand #zork`.
- `^ name ifNotNil: [:n | n asUppercase]` in a method declared `^<String>`
  gives `answers String | Nil where String is declared`.

When the members disagree about a block argument (Self on one side,
Dynamic on Nil's), the checker types the block once per member. It reports
only the first non-Nil member's diagnostics, and joins the results. The Nil
side's Dynamic produces no diagnostic and its block never runs, so a bottom
type is not needed.

Where the rule fails:
- A receiver whose type is a type parameter E that may include Nil. Inside
  the generic class, E is opaque, so the send is unchecked. Count in the
  image: **0** `ifNil:`-family sends.
- A union held in an instance variable: **2** sends. It works there,
  because the block parameter binds the value.
- A variable used again inside a zero-argument block, as in `v ifNotNil:
  [v foo]`. That needs flow narrowing, not a signature. The checker's
  zero-argument flow covers **19** reads that `memberwiseNil` alone loses
  (29 nil-flow reads in the base run, 10 with `memberwiseNil`;
  `results/image-memberwise.txt`). With `memberwiseNil` the image has 36
  diagnostics against 37; the one more in the base run is
  `ObjectTest>>testNilHandling`'s `nil ifNotNil: [:x | x + 1]`.
- 298 of the 313 `ifNil:`-family sends in the image have a Dynamic
  receiver, where neither rule has anything to say.

So a `T - Nil` operator can be left out. The signatures need `Self` and the
member-by-member rule. Flow narrowing for nil tests stays in the checker for
the zero-argument and `ifTrue:` forms.

### 2. What do generics cost?

- **Variance.** Invariant type arguments, with Dynamic as the way out. A
  type argument matches when each side is a subtype of the other, so Self
  and Dynamic both pass. Covariant arguments changed nothing in the slice:
  21 diagnostics either way (`results/matrix.txt`). The simple rule costs
  nothing that the kernel shows.
- **Generic methods** (inference of method variables at the send). Unify
  the non-block arguments, then type each block literal with the expected
  argument types, then bind the block's result. This costs about 60 lines
  of the checker (`OTMethodCheck>>apply:...`, `OTChecker>>unify:...`).
  Without them, sends with a known result fall 1500 → 1413 (−5.8 percent)
  in the slice and 382 → 379 in the tools slice. One diagnostic of the
  first run (`(items collect: [...]) first + 1`) and the tests' samples
  needed them. Without generic classes as well: 1405 known results, and 12
  fewer diagnostics, all of them limits. The kernel's own code gains
  little from generics. A client gains only when its own variables carry
  types. The tools slice has no annotations, and there `OrderedCollection
  new` is `OrderedCollection[Dynamic]`.
- **`Self`-typed collections.** `select:` answers `Self` in Collection,
  but OrderedCollection's answers `OrderedCollection[E]` (its `species`),
  and Interval's answers an Array. `collect:` is stated again in 6 classes.
  `Self[X]` would save those 6 lines at the price of higher kinds.
  Recommended: leave it out.
- **The cost on the class side.** Class-side methods of a generic class
  see the instance's parameters as Dynamic. Constructors bind them through
  `Instance[X]` (`meta with: <X> ^<Instance[X]>`).
- **What generics showed up as limits.** OrderedCollection's slots are
  `E | Nil` (8 diagnostics). `Interval[N]` lets `1 to: 5` be an
  `Interval[Integer]`, and `1 to: 2 by: 0.5` an `Interval[Number]`, at the
  cost of 5 diagnostics inside Interval, which would need the bound `N <:
  Number`. ByteArray has no side file, so it keeps `ArrayedCollection`'s E
  open (2 diagnostics).

### 3. How much annotation buys how much checking?

**First writing** (`results/first/`). 27 side files: 662 lines, 613
signatures, 17 variable types (`results/first/slice.txt`). They gave 55
diagnostics on the slice and 71 on the whole image. All 71 are classified
by hand in `results/diagnostics-first.txt`. The 67 that are not the
checker's own samples (more than the 50 the brief asks for):

| class | count |
|---|---|
| real fault (`BlockClosure>>ifError:`) | 1 |
| fault on purpose, in a test | 5 |
| wrong annotation | 21 (3.4 percent of the signatures) |
| limit: a class test that does not narrow (later implemented, `typeTests`) | 21 |
| limit: representation (OrderedCollection's nil slots) | 8 |
| limit: the result depends on the value (`Integer /`, `raisedTo:`) | 3 |
| limit: an unannotated subclass of a generic class (ByteArray) | 2 |
| limit: bounded generic (`Collection>>sum`) | 1 |
| limit: implicit protocol (`coerce:` sends `asFraction`, which Number lacks) | 1 |
| limit: `self class new` is Instance, not Self | 1 |
| limit: a method compiled by the test at run time | 1 |
| limit: no bottom type (`nil ifNotNil: [:x \| ...]`) | 1 |
| limit: nil in a generic slot | 1 |

The 21 wrong annotations were fixed. `Self` was written for arithmetic,
`retry:coercing:` was given a Number, and `Interval` was written over
Integer. `printOn:` was written to take `WriteStream[String]`, and
`select:` and `reversed` to answer `Self`. The stream's `collection` was
written as C, and `nextPutAll:` to take Object.

Before this classification, four faults of the checker itself were found
and fixed, because they made diagnostics that were neither faults nor
limits:
- class-side parameters were in scope;
- the receiver's Self mark was lost through generic variables;
- a primitive's failure code was taken as its result;
- an override in a class without a side file kept its superclass's
  signature. Now it does not: an unannotated override is not assumed to
  keep a signature.

**As it stands** (`results/slice.txt`, `results/image.txt`):

| | slice (annotated) | whole image |
|---|---|---|
| methods checked | 672 | 3040 |
| methods with a signature (own or inherited) | 650 | 650 |
| clean (no diagnostic) | 654 (97.3 percent) | 3008 (98.9 percent) |
| diagnostics | 21: argType 8, returnType 8, dnu 4, assignType 1 | 37: dnu 17, argType 10, returnType 8, arity 1, assignType 1 |
| sends | 2330 | 25 880 |
| receiver type known | 2076 (89 percent) | 13 248 (51 percent) |
| typed by a signature | 1835 | 6798 |
| result type known | 1500 | 8366 |
| check time | 120 ms | 1320 ms |

The image's 37: the real fault, the 5 intended ones, the 4 samples, and 27
limits of the kinds above.

### 4. What does an unannotated method get?

The tools' client slice has 0 annotations of its own: 243 methods, 1440
sends (`results/matrix.txt`).

| kernel side files | infer unannotated callees' results | receiver known | result known |
|---|---|---|---|
| yes | yes (the proposal) | 577 (40.1 percent) | 382 (26.5 percent) |
| yes | no | 554 (38.5 percent) | 173 |
| none | yes | 448 (31.1 percent) | 195 |
| none | no | 434 (30.1 percent) | 10 |

The inference comes from literals, `new`, class names, `self`, assignments
and annotated callees. An unannotated callee's result is inferred from its
body, cached, and only for a method without a primitive.

Without any annotation, a third of the sends have a known receiver. These
are `self`, literals and classes. The kernel's side files add a quarter to
that, and inferring callees' results doubles the known results. The slice
had 0 diagnostics. The client's instance variables are Dynamic, so most
sends to them are unknown. That is where a light annotation of a client
(its instance variables) would pay. It was not measured.

### 5. Is it live?

The whole image is checked once: 3040 methods in 1320 ms, building a
dependency index of 2505 keys and 12 544 edges (`results/image.txt`).

Then 20 changes are made, each one rechecked on a background Process
(priority 0) while the measuring Process waits (`results/live.txt`):

- **Ten leaf method bodies** were recompiled with `compile:` (Association
  key, Interval increment, Fraction numerator, Character isVowel, String
  trimmed, OrderedCollection removeFirst, Dictionary keysSortedSafely,
  Integer isPrime, WriteStream tab, Set hash). Each rechecked **1 method in
  67 to 962 µs**. Their callers read the signature, not the body, so an
  annotated method's body change is local.
- **Ten widely used signatures** were changed. Dependents rechecked, and
  time:
  - Object>>printOn: 6 (0.9 ms)
  - Collection>>do: 17 (4.3 ms)
  - Object>>printString 50 (38 ms)
  - Object>>= 166 (207 ms)
  - SequenceableCollection>>at: 170 (213 ms)
  - Object>>error: 306 (222 ms)
  - Boolean>>ifTrue: 453 (433 ms)
  - String>>, 579 (555 ms)
  - WriteStream>>nextPutAll: 66 (67 ms)
  - OrderedCollection>>add: 390 (450 ms)

  The diagnostic set followed each change. Making `printString` answer
  `String | Nil` added 17, `at:` answering `E | Nil` added 37, and `error:`
  answering Nil added 33. The image is inconsistent between changes by
  design, and nothing failed.

`Object>>printOn:` has only 6 dependents, because most `printOn:` sends
resolve to the signatures that subclasses state again. A dependency is on
the signature that was used, so a change of a superclass's signature does
not recheck the classes that override it. A module would add an
override-consistency check there.

Rechecking costs about 1 ms per dependent method, so the widest signature
takes half a second on a background Process. That is interactive for
diagnostics, but not for a keystroke.

### 6. Can the image propose types?

**From live values** (`results/proposals.txt`). `allSubInstances: 3000` of
each class of the annotated and the client slice was compared with the side
file's type of each instance variable:
- 122 instance variables had no instance in the headless image. The tools'
  models, the exceptions and the streams are transient.
- Of the 19 with instances: 6 proposals are the same as written, 11 are
  narrower, and 2 are wider. The narrower ones are all a concrete class for
  an abstract written type: SmallInteger for Integer, True for Boolean.
  The wider ones are `Association`'s generic K and V, where only Object can
  be proposed across instances.

So proposals need a running application, and they are concrete where
people write abstractions. A proposal should be rounded up to the class
that declares the protocol actually used. That is a rule of its own, and
it was not built.

The same file measures the element classes of the image's collections:
- OrderedCollection: 715 of one class, 48 of a common superclass, 2 empty;
- Array: 496 of one class, 6 of one class and nil, 1002 of a common
  superclass, 1008 mixed, 488 empty;
- Set: 49 of one class, 573 empty;
- Dictionary values: 11 of one class, 2 of a common superclass, 53 empty.

Most collections are homogeneous. The mixed ones are Arrays used as tuples
and literal arrays.

**From the tests, at run time** (`results/trace.txt`). This is a cheap way
without a VM change. 101 annotated methods with arguments in 11 classes
were recompiled with one statement first (`OTTrace note:args:`, which
records each argument's class). Then 55 of the kernel's tests of those
classes were run, and all 55 passed with the tracing in place. Of the
argument positions seen:
- 16 match the declared type exactly;
- 34 are declared wider than seen. 20 of those are Integer declared and
  SmallInteger seen;
- 48 are generic or block parameters, not compared;
- **0 saw a class outside the declared type.** No annotation was too
  narrow for what the tests do.

Primitives and the handler and unwind methods cannot be traced this way.
The tracing changes methods, so it is only for an image that is thrown away
afterwards.

### 7. What would the final syntax need? (not built)

Places Strongtalk-style annotations would touch. The counts are from
`scripts/syntax-scan.py` over `kernel/` and `tools/`
(`results/syntax-scan.txt`): 208 files, 2658 methods.

- **Both compilers.** The bootstrap parser (`Sources/KajoCompiler/`) and
  `kernel/Compiler/Parser.class.st` must read types in the same places:
  1953 argument positions, 2658 result positions (`^<T>` after the
  pattern), method temporaries (674 methods), block arguments (1111 block
  literals with arguments) and block temporaries (107). The compilers'
  corpus and the syntax fuzzer (its kernel mode compares the two) gain
  types at each place, with inputs written at the edges.
- **`<` after a pattern.** Today that is a pragma: 223 methods. 145 of
  them have arguments, so an argument type `<T>` would sit next to
  `<primitive: 60>`. The scan found 0 pragma names that start with a
  capital, and every type starts with a capital, `[` or `(`. So the rule
  "a `<` followed by a capital, `[` or `(` is a type" is unambiguous over
  the whole kernel, and a unary pragma `<unwind>` stays a pragma. This
  rests on a naming convention, so the compilers must refuse a capitalized
  pragma name.
- **Binary selectors.** 87 binary patterns. In 28 of them the selector
  holds `<` or `>` (`< aMagnitude <Magnitude> ^<Boolean>`). The scanner
  reads `<` and then a name, so there is no ambiguity, but a run of binary
  characters must not swallow the `<` of a type. `^<` and `||` appear 0
  times in bodies today. A type list must not end in `>>` or `>|`. The
  checker's own side files use `<...>` with brackets, never nested angles,
  for this reason.
- **The `|` of unions inside temporaries and block arguments.** In `| a
  <Integer | Nil> b |` and `[:x <T | Nil> | ...]`, the parser that today
  ends the temporaries at the next `|` must parse a type inside `<...>`
  first.
- **Tonel.** The bootstrap Tonel reader (`Tonel.swift`) ends a method's
  pattern at the first `[` outside a comment. A typed pattern then holds
  `Array[E]` or `[E, ^Boolean]`, and the reader would cut the method
  there. Both readers (Swift, and `TonelReader` in Smalltalk) and the
  writer's `Scanner class>>patternEndIn:` must skip `<...>` with its
  brackets. `scripts/canonical-tonel.sh --check` asserts byte identity, so
  the writer must write the types where they were read, with the recorded
  source unchanged.
- **Class definitions.** 384 instance variable declarations in `#instVars`
  lists. Types for them and a class's type parameters need new keys in the
  class definition (for example `#typeParameters : [ 'E' ]` and a type per
  variable). The class rules (`ClassRules`), the define and redefine
  primitives (145, 146), the Tonel writer and both readers, and the image
  format's class metadata would carry them. A side file per class, the
  experiment's form, is the alternative that touches none of these.
- **The source map.** Offsets are recorded per send in the body. Types in
  the pattern and temporaries only shift them, and the map is computed from
  the recorded source, so nothing changes but the corpus.
- **The tools.** The browser shows and edits methods as text, so it needs
  nothing new to keep types. Syntax colouring (`SourceColorer`) should
  colour them.
- **Not touched.** The bytecode, the verifier and the VM. A type compiles
  to nothing.

### 8. What would completion and the protocol need? (not built)

Questions an editor, a completion popup and an MCP client would ask, timed
on the tools slice in the image (`results/completion.txt`, microseconds):

| question | how the checker answers it | time |
|---|---|---|
| the type of every expression of a method | one check with types recorded | p50 109, p90 464, max 1872 |
| the type at a source offset | a lookup in that record | p50 2, max 15 |
| the selectors this receiver answers, with signatures | the class chain plus the side files | p50 340, max 797 (148 selectors at p50) |
| the diagnostics of a class | check its methods | p50 5.7 ms, max 41 ms |
| the dependents of a change | one index lookup | p50 1, max 7 |
| the diagnostics after a change | question 5's recheck | 0.07 ms to 0.55 s |

Every question is answered at interactive speed when the receiver's type
is known, and that is 40 percent of the client's sends (question 4). The
development protocol would need requests for these: `types.at` (method,
offset), `types.selectors` (expression or type), `diagnostics` (class or
method, with source ranges, which every diagnostic carries), and
`dependents`. It would also need an event that carries new diagnostics
after a background recheck. For an AI agent the diagnostic line itself is
the payload, in the form "kind Class>>selector:line text". The protocol
was not changed.

### 9. Types made from data at run time (a scripting dictionary)

**Demonstration** (`OTScripting`, `OTMeasure class>>scripting`,
`results/scripting.txt`, test `OTScriptingTest`). A scripting dictionary
in the shape of an sdef is a Smalltalk literal. It has 4 classes with
inheritance (`Mail.Item` ← `Mail.Message`, `Mail.Mailbox`) and typed
read-only and read-write properties. It has one to-many element
(`messages`), one enumeration (`Mail.Priority`), and one command (`move`)
with a direct parameter, a named parameter and an optional named
parameter. Code turns it into protocols (`OTProtocolInfo`, registered by
name in `OTAnnotations` in 78 µs):
- a property gives a getter;
- a read-write property also gives a setter answering Self;
- an element gives `^<Array[Proto]>`;
- a command gives one selector with the optional parameter (`move:to:withPriority:`)
  and one without (`move:to:`).

Six workspace expressions with `app <Mail.Application>` were checked:
- `app mailboxes first messages first subject asUppercase` is String;
- `... sender: 'me'` gives "Mail.Message does not answer #sender:"
  (`sender` is read-only);
- `app mailboxes first name: 'Archive'` gives "Mail.Mailbox does not answer
  #name:";
- `app move: ... withPriority: #urgent` is clean, because the enumeration
  is only Symbol.

The dictionary was then replaced by a second version: `subject` became a
`Mail.RichText`, `sender` became `from`, and Mailbox's name became
read-write. Registering it invalidated the protocols' keys and rechecked
**6 expressions in 849 µs**:
- the first expression now says "Mail.RichText does not answer
  #asUppercase";
- `sender` is reported missing;
- the mailbox setter is clean.

No Apple event, file, primitive or VM change was used.

**What this needs that questions 1 and 2 did not:**
- **Named protocol types**, not tied to a Smalltalk class, with a parent
  and replaceable by name. Questions 1 and 2 did not need structural
  protocols. This is the case for them, but only made by code, nominal by
  name, with no structural matching. The objects are proxies of one class
  whose real interface lives in data. Dynamic would be the honest way out,
  and it would lose everything the demonstration shows.
- **Enumerations.** Here an enumeration is Symbol. A Symbol set type would
  catch `#urgent`. Dynamic, or Symbol, is honest: the application refuses a
  bad value at run time. Leave it out until an agent's mistakes show it is
  worth it.
- **Optional keyword parameters.** Here they are expanded to one selector
  per combination. That is 2^k selectors for k optional parameters, fine
  for the usual 1 to 3. No new type feature is needed. A command with many
  optional parameters is better as a `Dictionary` argument, typed Dynamic.
- **Object specifiers.** A lazy reference to an application object, where
  the dictionary says a value, is a protocol type too. The difference is
  in the proxy, not in the type. A type for "reference to T" against "T"
  can be left out. Both answer T's protocol, and the bridge decides when
  to resolve.

**On resume.** A saved image keeps the protocols as data, but the
application's dictionary may have changed. The host should load the
dictionary again when the image resumes, or when it first connects to the
application. It should register the protocols again, and let the
invalidation recheck what read them, as the replacement above did. Until
then, the old protocols stand. Diagnostics are never a refusal, so stale
types cost wrong diagnostics, not failures. A protocol could record the
dictionary's version (the sdef's modification date or a hash) so that the
check can say when it is stale.

## The proposed type language

In:
- **Class types**, nominal, by inheritance. `Object` is the top, and `Nil`
  is UndefinedObject's type.
- **Generic classes** with declared parameters, and what each class gives
  its superclass's parameters (`super Foo[T]`). Type arguments are
  **invariant**, with **Dynamic** as the way out.
- **Block types** `[A, ^R]`.
- **Generic method variables**, inferred at each send from the arguments
  and from the block literals' results, including `X class`.
- **`Self`**, **`Self class`**, **`Instance`** and **`Instance[X]`**.
- **`T | Nil`** with Nil explicit, and **small unions**.
- **Overloads**: several signatures for one selector, first fit.
- **Dynamic**: never checked, the way out.
- **Flow in the checker**, not in the syntax: nil tests and class tests
  narrow a variable, a send to a union is checked member by member, and
  unannotated callees' results are inferred.
- **Protocols made by code**, by name, for data-defined APIs (question 9).

Left out, with the cost seen:
- structural protocols in annotations (0 annotations needed one);
- variance annotations (0 diagnostics changed);
- bounded parameters (6 diagnostics in Collection>>sum and Interval);
- `Self[X]` (6 restated `collect:` lines);
- a bottom type (`error:` answers Dynamic);
- tuples (brace arrays of unrelated classes are `Array[Dynamic]`);
- enumeration types;
- `T - Nil` and other type operators;
- user-declared type predicates;
- types on temporaries (not needed: flow inference typed them).

Prior art, read from memory (none of it is in `references/`):
- Strongtalk had nominal brands, structural protocols, generics, and
  `{where ...}` inference clauses for methods like `collect:`. The
  experiment's generic method variables do what those clauses did, by plain
  unification and without the clause syntax.
- Bracha's pluggable types argue that types must never change what a
  program does. That is the "diagnostics only" decision.
- TypeScript is unsound on purpose: `any`, bivariant method parameters, and
  narrowing by `typeof` and `instanceof`. The experiment chose the same
  trade: Dynamic, and narrowing by class tests.
- Sorbet's `T.nilable`, its flow narrowing on `nil?` and `is_a?`, and
  RBS's separate signature files are the closest in shape. Our side files
  are RBS's form.
- Typed Racket shows what soundness at the boundaries costs at run time.
  Kajo's VM never trusts a type, so it pays none of that.

## Decisions for the owner

1. **Nil explicit or nil in every type?**
   - Explicit (`T | Nil`, the `base` rows) gives 21 diagnostics on the slice
     against 12 with nil in every type (`nilLoose`). The extra 9 are all
     limits (OrderedCollection's slots), not faults.
   - The explicit form documents which values can be nil, and an agent
     reads that. With flow narrowing and `ifNotNil: [:v | ...]` it costs
     few diagnostics.
   - Recommendation: **explicit Nil**, with the flow rules.
2. **Overloads?** Without them, the slice has 145 diagnostics instead of
   21, nearly all from Integer arithmetic typed as Number. Recommendation:
   **in**, as an ordered list of signatures per selector.
3. **Narrowing by class tests** (`isKindOf:`, `isString`, ...)? This is a
   checker rule, not syntax, and it halves the diagnostics (45 → 21).
   Recommendation: **in**, for the fixed list of kernel testers. No
   user-declared predicates.
4. **Where do class-level types live in the final syntax?** Method types go
   inline, Strongtalk style, as decided. A class's type parameters and its
   instance variables' types need new keys in the Tonel class definition,
   carried through the class primitives and the image. Recommendation:
   **Tonel keys** (`#typeParameters`, and types in `#instVars`), decided
   with the syntax module. The alternative, a side file per class, avoids
   the image format but splits a class across two files.
5. **Protocol types?** Recommendation: **only made by code** (question 9),
   not in written annotations, until a written one is needed.

## What the first module would be

**Types 1: the syntax and the checker in the development image.**
- Both compilers read Strongtalk-style types in the places question 7
  lists and compile them to nothing. The parse tree keeps them.
- Tonel reads and writes them byte for byte, with a type-aware pattern end
  in both readers and in the writer.
- The corpus and the syntax fuzzer gain types.
- This experiment's checker moves to `tools/`, reading types from the
  parse tree instead of side files. It runs on a background Process after
  each install, with its dependency index.
- The diagnostics go out over the development protocol as events and as a
  `diagnostics` request.
- The kernel slice's 622 signatures move inline from the side files.
- Completion requests (`types.at`, `types.selectors`) and the browser's
  display would be the module after it.

## Deviations

- **Grammar measured by script, not by hand.** The brief said to try the
  grammar on paper against every method. A script counted the token
  sequences instead (`scripts/syntax-scan.py`). No parser was written.
- **Measured headless, through `kajo run`.** The brief said to measure in
  the development image. The measurements ran in an image built `--with
  tools` (the development image's contents), not the shells. The
  background Process of question 5 is a Process of that image.
- **Annotations corrected after the first run.** After the first run's
  classification, the 21 wrong annotations were corrected, and then
  `Interval[N]`, the streams' `collection` and `nextPutAll:` were annotated
  again. All of this was done before the numbers quoted "as it stands".
  The first run is kept in `results/first/`.
- **Four checker faults fixed before classifying.** They were found by
  reading the first run's diagnostics (question 3) and fixed before the
  classification.
- **Side files hold the ifNil: family twice.** The signatures that
  `memberwiseNil` uses are in `Object.types` and `UndefinedObject.types`.
  The base checker uses its own rule for that family first.

## Not done

- A client slice annotated lightly (its instance variables) to measure
  what generics then buy a client.
- An override-consistency check between a class's signature and its
  superclass's.
- The proposal rule that rounds a live value's class up to the declaring
  abstraction.
- Measuring the checker in the shells or on a device.
- Narrowing by `class ==` is implemented, but the kernel had no instance of
  it that counted.
