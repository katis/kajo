# Module 8e: live classes (defining, reshaping and writing out classes from Smalltalk)

Status: brief, written 2026-11-04 from module 8d's Not done list and what
module 9b (the development protocol and the developer UI) will need
underneath it. Builds on 8d (`docs/modules/kernel-live.md`: the make and
install primitives, the release flag, class variables, the sealed classes)
and on module 1's reshape and instance enumeration
(`docs/modules/object-memory.md`). The as-built doc replaces this file.

## Why

8d made methods live: a running image compiles and installs them. Classes
are not: the class objects are sealed and made only by the image build, a
class variable pool is fixed at build time, method categories are dropped
on install, and nothing writes an image's classes back to the Tonel files
under `kernel/`. A developer UI or an agent that edits a running image
needs all four, or every class-level change means a rebuild from files and
a lost image. This module makes the image the editor's model: a class can
be defined, changed in shape and written out, and the files on disk follow
the image rather than the other way round.

## What it hides

- How a class comes to exist or changes shape in a running image: which
  primitives, in which stop, with which checks, and what happens to the
  instances and the methods that exist when the shape changes.
- Where a method's category and a class's comment live in the image.
- How the image's classes become Tonel files, and what "the same" means
  between a file and the image (a canonical form).

## 1. Defining and removing classes

A **define-class primitive** (new; number from the kernel primitives'
range, in ADR 0009's table) makes a class and its metaclass from a
specification the kernel builds (name Symbol, superclass, instance
variable names, class-side instance variable names, class variable names,
format kind as Tonel's `#type`, category Symbol, comment String). It runs
in the install stop with the checks the image build's `defineKernelClasses`
makes (shared code, not a copy): the superclass is a class the image
knows, no subclass of a sealed class, a format compatible with the
superclass's, names that shadow nothing, a name not already bound. It
makes the pool of Bindings (8d), registers the class with the system
dictionary (`Smalltalk at:`), and answers the class. In a release image
it fails and the kernel signals InstallForbidden, as 8d's primitives do.

`Class>>subclass:instanceVariableNames:classVariableNames:category:` and
the Smalltalk-80 family on top; a Tonel class definition read by the
kernel's compiler (Tonel in the image: see 4) uses the same path.

**Redefining** an existing class with the same name and a changed shape is
section 2. Redefining with a different superclass: refuse in this module
(record it as not done) unless it falls out of the reshape cleanly.

**Removing** a class (`Smalltalk removeClass:`): refused while it has
subclasses or instances (module 1's instance enumeration, inside the
stop so no instance can appear meanwhile) or while any method's literal
frame names it (the compilers bind a class reference how? read 8b; if a
method holds the class object itself, enumerate the methods; if it holds
a Binding, the binding becomes undeclared and a send to it fails with a
clear error). Then its methods go, its Bindings are forgotten, the system
dictionary drops it. Sealed classes cannot be removed.

## 2. Changing a class's shape

Adding or removing an **instance variable**, a **class-side instance
variable** or a **class variable** on a live class:

- Instance variables: the class's format and every subclass's change;
  every existing instance of the class and its subclasses is reshaped by
  module 1's reshape (new slots nil, removed slots dropped) in the stop;
  every method of the class and its subclasses (both sides where the
  change is class-side) is **recompiled** from its recorded source by the
  compiler in Smalltalk and re-installed through 8d's make and install
  primitives, since instance variable indices are compiled in. A method
  that no longer compiles (it names the removed variable) is reported by
  name and the whole change is refused before anything is reshaped: the
  recompile is checked first, the reshape and the installs happen only
  when every method compiled, so a failed change leaves the image as it
  was. Sealed classes refuse.
- Class variables: the pool Array is replaced (a new read-only Array of
  Bindings) in the stop; methods that name a removed Binding keep the
  Binding object, which becomes undeclared: a read answers nil and a
  write signals an error naming it, as Pharo's undeclared variables do, so
  that a developer can remove, then re-add, without recompiling the
  world. Adding a class variable recompiles nothing (new methods bind to
  the new Binding).
- Decide, and write down, what a Context (8a) or a saved Process (8c)
  holds when a method it is running is replaced by the recompile: the
  old method object stays valid (8d's install already allows it), the
  frame keeps running the old code with the old indices against a reshaped
  receiver. That is wrong for the running frame. Either refuse a reshape
  while any frame runs a method of the class (enumerate the stacks in the
  stop, 8c's loader walks them already) or document that the running
  frame reads the old layout; refusing is the safe default, with the
  error naming the Process and method, and a developer tries again when
  the Process has left. Build that and say why.

A **reshape primitive** (new) does the slot change and the format change
for a class and its subclasses in one stop; the recompile and the checks
are the kernel's. Measure the stop's length for a class with 10 000
instances and 50 methods.

## 3. Categories and comments in the image

Method categories survive `compile:classified:` and `Behavior>>compile:`
(default category `as yet unclassified`), live in the image (where 8b
keeps sources, per class), and are readable (`Behavior>>categoryOf:`,
`organization`, `selectorsInCategory:`, `categories`). The class comment
and the class category are already in the image (check; add what is
missing). The image build keeps every category the Tonel files carry;
`CompilerTest`'s round trip extends to categories.

## 4. The Tonel writer, and Tonel in the image

A **Tonel writer in Smalltalk**: `Class>>tonelSource` answers the file's
text for a class (the comment, the class definition with every key the
reader accepts including `#classVars`, then the methods grouped by
category in a canonical order: class side after instance side, selectors
sorted, each method's recorded source as recorded, indentation
normalized to the kernel's one tab), and `Smalltalk writeTonel: aDirectory`
writes every class not sealed, and the sealed ones too, as files named
`<Class>.class.st`, through a file primitive (new: write a String to a
path, create or replace; and read a path; both refused in a release
image; nothing else of a file system in this module). Extensions
(`Extension { #name : ... }`) are written for methods a class got outside
its own definition if the image records that; otherwise everything is in
the class's file and the doc says so.

**Canonical form.** Write every kernel class out of the image built from
`kernel/` and compare with `kernel/`: where they differ only in
whitespace or method order, rewrite `kernel/` once to the canonical form
in its own commit (the compiled methods must match method for method
before and after, by `CompilerTest`'s comparison on the two images). After
that commit, a test builds the image from `kernel/`, writes it out, and
asserts every file is **byte-identical** to the one it was built from.
That test is the contract between the image and the files: edits made in
the image can be written to disk and committed, edits made on disk build
the same image.

**Tonel in the image** (the reader in Smalltalk): `Smalltalk readTonel: aString`
parses one file (STON class definition, methods) with the compiler in
Smalltalk and defines or redefines the class through sections 1 and 2,
installing every method. A test reads a written file back into a fresh
image and compares class and methods. The bootstrap reader in Swift stays
the image build's and the oracle: a test parses every kernel file with
both and compares the definitions and the method lists.

## Rules

AGENTS.md binds the build. In particular:

- Zero ARC on hot paths and one jump table in `interpret`; none of this
  module is a hot path, but the reshape touches every instance, so its
  stop is measured and the `just bench` A/B (aligned builds, 5 runs
  interleaved, 1 and 8 workers) stays within noise.
- `.strictMemorySafety()`; count the unsafe constructs. The file
  primitives take a path from Smalltalk: refuse anything outside the
  directory the host opened the VM with (`kajo run --sources <dir>`, the
  shell's option; no directory, no file primitives), and say so.
- Every structural change goes through a primitive that re-checks what
  the image build checks: the primitive is the trust boundary, as 8d
  says. Seeded mutations of class specifications through the define
  primitive (1500, as 8d's method mutations) refused or accepted without
  a crash; the snapshot fuzzer's seed corpus gains an image with a class
  defined and reshaped at run time.
- Tests assert on work, never on wall-clock time; models updated with
  any protocol they cover (the install stop is expected to cover all of
  this; say why in the doc, or model what it does not).
- Every gate green on the final commit, output in files: `swift test`
  debug, under load, ThreadSanitizer alone and under load, `just
  ios-check`, `just arc-check`, `just golden`, `just test-release`,
  `just model-check`, `just soak`, `just fuzz kasm|snapshot|syntax 600`
  with "libFuzzer build: ok", `just apps`, a clean build with 0 warnings.
- Do not edit AGENTS.md or docs/PLAN.md.

## Deliverables

- The primitives (define class, reshape, write file, read file), the
  kernel protocol above, the Tonel writer and reader in Smalltalk, the
  canonical `kernel/` commit, the tests.
- This file replaced by the as-built doc in the style of
  `docs/modules/kernel-live.md`; ADR 0009 "Built (8e)" (the primitives, the
  undeclared Binding rule, the running-frame rule); `docs/CONTEXT.md`
  (canonical form, undeclared, reshape); `kernel-live.md`'s Not done
  entries this closes marked closed.
- Open questions for the owner: whether redefining with a new superclass
  belongs here or in 9b; whether the file primitives' directory rule is
  right for the shells; anything the running-frame decision leaves open.
