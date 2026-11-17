# Types 2: the checker in the development image

## Status

Brief, written 2026-11-17 by the main session. The owner on the 45
signatures Types 1 could not move inline: "Use the Self type where possible,
then do option 3, the form without for a signature without a method, design
a consistent syntax." On the proposed form: "Approve". On the rest: "approve
your recommendations for the other questions". The records are
`docs/decisions/43-optional-types.md` and `44-types-1.md`; the experiment is
`experiments/optional-types/RESULTS.md`; the syntax is
`docs/modules/types-1.md`.

Not started. The owner starts it.

## What it is

The types are in the source and nothing reads them. This module makes them
checked: the experiment's checker becomes a package of the repository that
reads the types where Types 1 put them, runs on a background Process after
every change, and gives its diagnostics over the development protocol. Its
first part is the last piece of syntax, a signature without a method, and
the placing of the 45 signatures left in the experiment's side files.

Diagnostics only. The VM never trusts a type, nothing is refused because of
a type, and a release image holds no checker and no type table.

## What is known

- The experiment's checker: 3 749 lines of Smalltalk in 28 classes
  (`experiments/optional-types/OptionalTypes/`: `Types/` 12 classes,
  `Checker/` 4, `Annotations/` 4, `Scripting/` 3, `Measure/` 3, `Tests/` 3).
  It reads side files (`annotations/*.types`) through `OTAnnotations` and
  `OTTypeParser`.
- Its numbers, headless on the mini: the image's 3040 methods checked in
  1.3 s with a dependency index of 2505 keys and 12 544 edges; a changed
  method body rechecks 1 method in under 1 ms; a changed signature rechecks
  6 to 579 methods in 0.9 to 555 ms; 21 diagnostics on the slice and 37 in
  the image; about 1.2 MB held for the slice, 349 KB of it type objects.
- Types 1 (85a172a): both compilers keep `argumentTypes` and `resultType`
  on `MethodNode` as `TypeNode`s with source ranges; class-level types are
  text in `Smalltalk`'s `classTypes` table (`ClassTypes`), which a release
  build does not fill; 577 signatures, 15 type parameters, 4 superclass
  types and 17 instance-variable types are inline in 27 kernel files; 45
  signatures are still only in the side files
  (`~/kajo-scratch/types-1/work/inline.txt` lists them).
- A release image is the same bytes as a plain one with a flag set: it
  keeps every class it was built with. "Not in a release image" therefore
  means "not built into it".
- A generated app's image is `kernel/` plus the project's `src/`
  (`Sources/KajoGenerator/Templates.swift`, `build-images.sh`). It does not
  hold `tools/`. The tools run in the Kajo app's image and reach the app
  over the development protocol.

## The decisions already made

### The signature without a method

A method entry with no body: the same metadata, the same `Class >> pattern`
with its types, and no brackets.

    { #category : #'bit manipulation' }
    Integer >> bitAnd: anInteger <Integer> ^<Integer>

    { #category : #accessing }
    SequenceableCollection >> at: index <Integer> ^<E>

- The pattern is the method pattern of Types 1: overloads (`;`), method
  variables (`:X`), `Self` and `Instance` as on a method.
- It stands among the class's methods in the canonical order by selector,
  under its category, on either side (`Foo class >> ...`).
- After the pattern a `[` starts a method's body; the next entry's `{`, a
  comment string or the end of the file ends a signature; anything else is
  refused in both readers with the same reason.
- A class file has a method or a signature for a selector, never both.
- It is nothing to the VM: no CompiledMethod, no method dictionary entry,
  `respondsTo:` and `includesSelector:` unchanged. It is text in the
  class's `ClassTypes`, with its category; a release build holds none.
- The checker's lookup, upward from the type's class, takes the first
  method or signature it meets. A signature that narrows an inherited
  method is checked against it (a diagnostic, as everything is).
- In the browser the command decides the kind, never the text. That
  command is not in this module.

### The 45

1. `Self` on the method the lookup finds, where it says the truth:
   `Number >> + aNumber <Self; Number> ^<Self; Number>` (and `-`, `*`,
   `\\`), `negated ^<Self>`, `abs ^<Self>`, `Magnitude >> max: aMagnitude
   <Self; Magnitude> ^<Self; Magnitude>` and `min:`.
2. Where `Self` is wrong, the class's own method says so: SmallInteger and
   the large integers (a sum can change class) carry `<Integer; Number>
   ^<Integer; Number>`; Fraction answers `Number`.
3. The 15 of `Object class` go on Behavior's own methods.
4. `Integer>>//` is dropped: Number's answers Integer.
5. The rest are signatures without a method: Integer's `bitAnd:`, `bitOr:`,
   `bitXor:`, `bitShift:`; `SequenceableCollection>>at:` and `at:put:`;
   `Array>>collect:`; `Interval>>select:`; Number's four comparisons;
   `ArrayedCollection class>>new:`.

This placing is a plan, not a measurement. Part 1 measures it.

## Starting positions

Each is the main session's belief. Part 1 says right or wrong with a number.

1. The placing of the 45 gives the slice no more diagnostics than the side
   files did (21). It can be measured before anything is built: copy the
   side files to the scratch directory, rewrite them to the placing above
   (the side files can already say `Self` and overloads) and run the
   experiment's checker on the copy.
2. Both Tonel readers can tell a signature from a method by the one token
   after the pattern, over every class file of `kernel/`, `tools/` and
   `apps/Shared/smalltalk`, and a method whose `[` was forgotten is refused
   with a line and not read as a signature followed by garbage.
3. The checker can run in the image whose code it checks with no new
   primitive and no change under the core directories: it reads classes,
   sources and `ClassTypes`, and hears of a change through something the
   kernel already has or a plain Smalltalk hook.
4. Reading types from the parse tree is no slower than reading side files:
   the whole image is checked in about 1.3 s and a method body rechecks in
   under 1 ms.
5. A development image with the checker loaded and the image checked holds
   2 to 4 MB more than one without (the experiment's extrapolation).

## Parts

1. **Measure and decide, build nothing else.** Starting positions 1 and 2
   (a scan, as Types 1's `scan.py`), and the baselines for 4 and 5 on the
   starting commit. Write the rules of the signature form that this brief
   leaves open (open questions 2 and 3) with their reasons. Commit before
   part 2.
2. **The signature without a method**: both Tonel readers, the writer in
   its canonical order, `ClassTypes` holding the pattern's text and the
   category, `TonelLoader`, `ClassBuilder` and class removal keeping the
   table right, the project write-back (`ProjectWriter`) writing a
   signature back to its class file. Byte identity on the round trip.
3. **The 45 placed** by a script kept under the experiment's `scripts/`.
   This is the first use of the overload form in the kernel. The side files
   and the experiment's checker stay as they are.
4. **The checker as a package** in a directory of its own (open question
   1), reading method types from the kernel compiler's `MethodNode`,
   class-level types and signatures from `ClassTypes`, and no side file.
   `OTTypeParser` goes; the types are built from `TypeNode`s. The
   experiment's `Measure/` stays in the experiment. Its tests move with it
   and gain the cases below.
5. **Live**: the checker hears of every installed, changed and removed
   method, signature and class, and rechecks the dependents on a
   background Process below the user's priority. It waits untimed when it
   has nothing to do. A burst of changes (a class file loaded) is one
   recheck, not one per method.
6. **The protocol**: one request, `diagnostics` (the image, a class or a
   method; each diagnostic with its kind, class, selector, line, source
   range and text), and one event when a background recheck changed the
   set. A target without the checker answers the request with a clean
   refusal. The MCP server offers the request. Nothing in the tools'
   windows.
7. **Where it is built in**: the development image (`just dev-image`), the
   shells' images, and a generated app's Debug image; never a release
   build. The checkout `scripts/dist.sh` makes carries the package.
   `new-check` asserts that a Release app's image holds no class of the
   checker and no type table.

## Tests

Before the code where possible.

- The signature form through both readers: a table of files (a signature
  first, last, between methods, on the class side, with overloads and
  method variables), the same result from both, and the refusals alike
  (a signature and a method for one selector, a signature with a body-less
  typo such as a missing `[` before statements, a signature in a file of a
  release build's input is read and dropped).
- The round trip of every class file with a signature, byte identity, and
  `scripts/canonical-tonel.sh --check`.
- The syntax fuzzer gains seeds with signatures, both modes; the compilers'
  corpus is not affected (a signature is not compiled) and a test says so.
- The checker's 24 tests on inline types, plus: `Self` in an argument
  place with an overload (`3 + 4` is an Integer, `3 + 4.5` a Number, the
  same for a receiver typed `Integer`), a SmallInteger sum is an Integer
  and not a SmallInteger, a signature without a method found by the
  lookup, a narrowing signature that contradicts the inherited method.
- Live: a method body changed rechecks that method; a signature changed
  rechecks its dependents; a class removed drops its diagnostics; a file of
  many methods loaded is one recheck. The idle checker makes no timed wait
  (a test that work after idling completes within a bound, as the house
  rule says).
- The protocol: the request's three scopes, the event after a change, a
  malformed request is a reply, a target without the checker refuses
  cleanly; `fuzz-protocol` gains the request as a seed.
- A release image: no checker class name and no signature text in its
  bytes (a marker, as Types 1's test).
- Broken variants, each failing a named check: the reader takes a missing
  `[` as a signature; the lookup skips signatures; `Self` in an argument
  place is taken as the declared class; the recheck after a signature
  change is left out; the release build is handed the signatures.

## The bar

- The slice's diagnostics are no more than part 1 measured for the
  placing, and each one is classified (a fault, a limit, a wrong
  annotation) as the experiment classified its own.
- Every method of the image still compiles to the bytecodes it had; both
  compilers agree; `scripts/canonical-tonel.sh --check` lists nothing.
- The image checked and a body rechecked in the times of starting position
  4, on the mini, headless; say the numbers beside the experiment's.
- What the checker holds, measured as the experiment measured it, in the
  development image and in a generated app's Debug image.
- A Release app's image and binary are the size they were on the starting
  commit, up to the signatures' own source text if part 1 finds a place
  that keeps it; say the bytes.
- The kernel's tests, the tools' tests, the experiment's 24 tests on its
  own image, `just check <starting commit>` on the final code commit, and
  the fuzzers the diff chooses with their "libFuzzer build: ok" lines.
- One run of every switch and mode the module adds, quoted.

## Rules of the house that bind here

- The primitive is the trust boundary: nothing a type or a signature says
  changes what the make primitive, the verifier or the class rules accept.
- The development protocol is a trust boundary: the request is parsed and
  checked in the target, a malformed one is a reply, a release image does
  not serve.
- What a release image must not hold is decided by where it is stored.
- A syntax change is checked against every reader of source.
- Idle threads and Processes wait untimed; a wait for something that must
  come is long everywhere; a test of work under load asserts what must
  have started.
- A table that grows with the kernel is split per class (the 4095-slot
  lesson is gone with large objects, but the dependency index's size is
  measured on the whole image, not on the slice).
- A count from a script is checked on three rows by hand.
- A new slow kernel test changes the test parts; run the kernel tests in
  parts before the gate run.
- Known thin tests, not this module's: `ToolsTests.aClassDefinedIntoATag
  FromTheBrowserMovesWithItsTag` (once, "another Process holds
  ToolsTagProbe on its stack") and the weekly's interning pair before
  their fix. A failure of one of those is reported as what it is.

## Not in this module

- Anything in the tools' windows: diagnostics in the browser, a "New
  signature" command, types shown apart from the text.
- Completion (`types.at`, `types.selectors`) and `dependents` over the
  protocol.
- Proposals of types from live values.
- Annotating more of the kernel than the slice.
- Types on temporaries and block parameters.
- Native code or the interpreter reading a type.

## Deliverables

The code and tests above; this doc with a "Part 1" and an "As built"
section (each starting position's answer, the numbers with their files, the
diagnostics classified, gates, deviations, not done, found); work files in
`~/kajo-scratch/types-2/`.

## Open questions

1. **Where the checker lives and runs.** The experiment and the records
   said "`tools/`". But `tools/` is the Kajo app's image, and a generated
   app's image does not hold it, so a checker there could not check an app
   on a phone. Recommended and assumed above: a package of its own
   (`types/`, beside `kernel/` and `tools/`), running in the image whose
   code it checks, built into development images and Debug app images and
   never into a Release build. The cost is its memory and its background
   Process on the device, which part 1 and the bar measure. The other way
   is a checker in the tools' image that mirrors the target's signatures
   over the protocol.
2. **A method installed where a signature stands.** Recommended: in a class
   file both are refused; in the image the method replaces the signature
   (a live change must not be refused for a type), and the class file
   written back has the method.
3. **A signature for a selector the class's own superclass chain and
   subclasses never answer.** Recommended: a diagnostic on the signature,
   nothing more.
4. **The checker's class names.** The experiment's are `OT...`.
   Recommended: plain names with `Type` in them, decided in part 1 against
   the kernel's and the tools' names.
5. **A switch to leave the checker out of a Debug app.** Recommended: not
   yet; measure first what it costs on the devices.

## Part 1: measured and decided (2026-11-17, 1e8f324)

Measured on the mini with swiftly's swift.org 6.4.2 first on PATH, with an
aligned release `kajo` of the starting commit
(`-align-all-nofallthru-blocks=5 -align-loops=32`). Raw files in
`~/kajo-scratch/types-2/part1/`, scripts in `~/kajo-scratch/types-2/scripts/`
(`place45-sidefiles.py`, `ot-run.sh`, `part1-ot.sh`, `scan-sp2.py`,
`T2Measure/`, a scratch extension of the experiment's `OTMeasure` with one
measurement, `footprintImage`). Nothing was built.

Before anything changed, the gates the Swift tier skips were run on the
starting commit: `just golden` passed every kernel (`golden-1e8f324.txt`,
rc=0) and the Mac shell's tests mode passed 255 of 255
(`mac-tests-1e8f324.txt`).

### The starting positions

1. **Wrong: the placing gives the slice 30 diagnostics, not at most 21.**
   The experiment's checker over its own side files on this commit gives the
   slice (its 27 classes) 20 diagnostics, not 21, and the whole image 42, not
   37 (the image has 3111 methods now, Types 1's code among them;
   `ot-orig/slice.txt`, `ot-orig/image.txt`). The placing, written in the
   side files' own form (`place45-sidefiles.py`: Number's `+ - * \\` as
   `<Self> ^<Self>` then `<Number> ^<Number>`, `negated` and `abs` `^<Self>`,
   Magnitude's `max:` and `min:` the same with Magnitude, Integer's 15 lines
   removed, side files for SmallInteger and LargePositiveInteger with
   `<Integer; Number>` on `+ - * \\` and `^<Integer>` on `negated`, Fraction's
   `+ - *` answering Number, Object's 15 class-side lines moved to Behavior's
   instance side), gives the same 27 classes 30 (`ot-placed/slice.txt`; 30 over
   all 30 annotated classes, the 3 new side files add none) and the image 56.
   The 10 more, each classified (`ot-placed/slice-diagnostics.txt` against
   `ot-orig/`):
   - 7 **limit: `self species new:` answers Instance where Self is declared**
     (Collection>>select:, SequenceableCollection>>`,`, `copyFrom:to:` twice,
     `copyWith:`, `reversed`, `select:`). This is the experiment's own
     limit "`self class new` is Instance, not Self" (Dictionary>>select:, 1
     of the 20). It appears now because the 15 class-side signatures apply
     for the first time: the experiment's checker never looked a class-side
     send up in Behavior, and its rule that an unannotated override voids
     the signature above it voided every one of Object's 15 (their methods
     are Behavior's, which had no side file). With the 15 left as Object's
     `meta` lines the placing gives 23 (`ot-placed-meta/`).
   - 3 **limit: Self cannot be shown from arithmetic**: `Number>>negated`
     (`^ 0 - self`), `Float>>negated` and `Fraction>>negated` answer Number,
     Float and Fraction where `^<Self>` is declared. True at run time (but
     for SmallInteger minVal and a large negative's `abs`, said below), not
     provable by the checker.
   - The image's 4 more besides these: 2 dnu of a method a test compiles at
     run time (`CompiledMethod >> #developmentExtensionSample`, now typed
     through Behavior's `compiledMethodAt:`), 2 maybeNil in the same kind of
     test code (`lookupSelector:` answers `CompiledMethod | Nil`).
   None is a wrong annotation and none a fault. The checker of part 4 types
   `self class` and `self species` instance creation inside an instance
   method as Self (the receiver's class makes an instance of the receiver's
   class), which answers the first 7 and the experiment's Dictionary>>select:
   (part 4 says what it measured). The bar's "no more than part 1 measured
   for the placing" is 30 for the slice.
2. **Right, with the rule taken as "the token after the pattern decides"**
   (`scan-sp2.txt`). Over the 216 class files of `kernel/`, `tools/` and
   `apps/Shared/smalltalk`, all 2754 methods have `[` right after the
   pattern. With each one's `[` taken away, the body's first character is a
   comment for 762, `]` for 2 (empty bodies) and a statement or pragma for
   1990; no body starts with `{`. Read as the brief's words ("a comment
   string ends a signature"), 762 forgotten brackets would be read as a
   signature and the reader would then fail at the next entry, on another
   line with another reason. Read with comments skipped, as the Parser's
   scanner skips them, the token after the pattern is `]` or a statement in
   all 2754, and every one is refused at the pattern with "expected [ after
   the method's pattern" and its line. So the rule built is: after the
   pattern, comments skipped, a `[` starts a body; a `{` (the next entry's
   metadata) or the end of the file ends a signature; anything else is
   refused. A comment between a signature and the next entry is allowed and
   not kept (the canonical form writes none there).
3. **Right in substance, with one plain Smalltalk hook.** Nothing the
   checker reads needs a primitive: classes and method dictionaries,
   `Smalltalk sourceOf:`, `Smalltalk typesOf:` and the kernel's `Parser`
   (`parsePattern` gives the types of a pattern without the body). What the
   kernel has for changes is `DevProtocol noteChangeOf:in:`, called by
   `Behavior>>compile:classified:` alone (not by removal, class definition,
   redefinition or removal, or a change of a class's types), and it is
   about packages. So part 5 adds one hook in `Smalltalk`, a listener that
   is nil unless the checker set one, called from those places, and a
   bracket `Smalltalk changesDuring:` that the Tonel loader puts around a
   file so that a file is one change. No file under the core directories.
4. **Baselines on the starting commit** (the experiment's checker, the
   aligned release `kajo`, one worker, headless): the whole image (3111
   methods) checked in 1434, 1441 and 1449 ms in three runs
   (`ot-orig/image.txt`, `footprint-image.txt`, `live.txt`), dependency index
   2559 keys and 12 955 edges; a changed method body rechecks 1 method in 91
   to 928 µs; a changed signature rechecks 6 to 591 methods in 0.96 to 570
   ms (`ot-orig/live.txt`). Part 4's number is compared with these, on the
   same kind of build.
5. **Baseline, and the brief's number is low for the whole image.** The
   experiment's estimate (a walk: two header words and eight bytes a slot)
   of what its checker holds after checking the whole image, not the slice
   (`ot-orig/footprint-image.txt`): type objects 348 552 bytes, dependency
   index 872 408, inferred-result cache 486 080, diagnostics 445 648, the rest
   of the per-method records 2 604 424; about 4.76 MB in all, against 1.2 MB
   for the slice (`ot-orig/footprint.txt`, the experiment's number again).
   The image files: the development image 8 360 888 bytes, the kernel
   6 950 800, the kernel's release image 6 929 840, the development image
   with the experiment's package (and the scratch measurement) 9 602 872
   (`work/`, built by the same `kajo`). Part 4 keeps per method only its
   diagnostics and its dependency keys, as the experiment proposed, and
   measures again.

### The rules of the signature form this brief left open

- **The token rule** (starting position 2): after the pattern, comments
  skipped, `[` a body, `{` or the end of the file a signature, anything else
  refused with "expected [ after the method's pattern".
- **A signature writes at least one type.** `Foo >> bar` followed by the next
  entry is a method whose body was forgotten, not a statement about types;
  both readers refuse it: "a signature writes at least one type".
- **One per selector and side.** A file with a method and a signature for one
  selector on one side is refused in both readers ("Foo>>bar is both a method
  and a signature"); so is a signature written twice ("a signature for
  Foo>>bar twice").
- **Its category** is its metadata's, as a method's; none is
  `as yet unclassified`. **Its package** is its file's: a signature may stand
  in an `Extension` file as a method may, and is written back into that
  package's extension file.
- **Its text** is the pattern as written, from the selector to the pattern's
  end (the Parser's `lastEnd`), kept in the class's `ClassTypes` by side and
  selector with its category and package; the writer puts it in its
  category in the canonical order by selector, `{ #category : ... }` on its
  line and `Class [class] >> <text>` on the next, so the round trip is byte
  for byte. A release build hands none over (the image build does not send
  them, as it sends no class-level type), so a release image holds no
  signature's text.
- **Open question 2, as recommended**: in a class file a method and a
  signature for one selector are refused (above); in the image a method
  compiled where a signature stands replaces it (`Behavior>>compile:`
  forgets the signature), so the class's file written back has the method.
  A signature added where a method stands is refused (`Behavior>>signature:
  classified:` answers a ClassDefinitionError); the browser has no command
  for it in this module.
- **Open question 3, as recommended**: a signature for a selector that
  nothing in its class's superclass chain or subclasses answers gets one
  diagnostic of the kind `signature` on the signature, nothing more.
- **A narrowing signature is checked against what it narrows** (the brief's
  decided rule, the owner's "Approve"): the first method or signature above
  the signature's class for the same selector. It contradicts it when its
  result is not a subtype of the inherited result, or when an argument's type
  is neither a subtype nor a supertype of the inherited argument's (Self
  read as the signature's class on both sides). Arguments are compared both
  ways, as TypeScript compares method parameters, because the owner's
  placing narrows four on purpose: Number's comparisons take a Number where
  Magnitude's take a Magnitude. A contradiction is a diagnostic of the kind
  `signature` on the signature.
- **The lookup** (the brief's "the first method or signature it meets"),
  with the experiment's rule for a method without types kept: upward from
  the receiver's class (for a class-side send, from its metaclass through
  `Object class`, `Class`, `ClassDescription` and `Behavior`), a signature or
  a typed method of a class is the answer; a method with no type is the
  answer (none: its result is inferred) when its class carries no type at
  all, and is passed over when the class carries any (a typed method, a
  signature or a class-level type), as an unannotated override in an
  annotated class kept its superclass's signature in the experiment.
- **Open question 4, decided against the kernel's and the tools' names**
  (none of these names occurs in `kernel/`, `tools/`, `apps/Shared/smalltalk`
  or a Swift source; `ClassTypes` is the kernel's, so the experiment's class
  type is not `ClassType`): `Type`, `NominalType` (OTClassType), `MetaType`,
  `UnionType`, `BlockType`, `SelfType`, `SelfClassType`, `InstanceType`,
  `TypeVariable`, `TypeVariableClass`, `DynamicType`, `UnassignedType`,
  `ProtocolType`, `TypeProtocol` (OTProtocolInfo), `TypeSignature`,
  `TypedClass` (OTClassInfo), `TypeTable` (OTAnnotations, reading the image
  instead of side files), `TypeChecker`, `MethodTypeCheck`, `TypeScope`
  (OTEnv), `TypeDiagnostic`, and `TypeService` (the live part, new), with the
  tests `TypeCheckerTest`, `TypeCheckerSample`, `ProtocolTypeTest` and
  `TypeServiceTest`. The package is `types/` (package Types). `Types`
  joins the names `kajo new` refuses for an app, beside `Kernel` and
  `Tools`.
- **When the checker runs.** It is loaded in a development image but checks
  nothing until it is first asked: the first `diagnostics` request (or
  `TypeService start` from Smalltalk) checks the whole image on its
  background Process and from then on rechecks after every change. A
  development app that no client asks pays the classes' memory and nothing
  else, and the shells' scenario images, which the matrices measure, are
  not changed (the development images are; part 7).
- **Open question 5, as recommended**: no switch.

The placing of the 45 is built as the brief writes it (part 3), with the 7
Instance diagnostics answered in the checker (part 4) and the 3 negated ones
left as a limit. Two more places where Self is not the whole truth are kept as
the owner's words put them and written down: SmallInteger's `negated` and
LargePositiveInteger's carry `^<Integer>` on their own methods (a negation
can change class, as a sum can), but `abs` of SmallInteger minVal and of a
large negative integer changes class too and has no method of its own in
those classes to say so.
