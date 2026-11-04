# Module 8d: live compilation (per-iteration temp vectors, class variables, installing from Smalltalk)

Status: brief, written 2026-11-04 from the owner's answers to module 8b's
open questions (`docs/modules/kernel-image.md`, "Open questions for the
owner"). Builds on 8a (`docs/modules/object-model.md`), 8b
(`docs/modules/kernel-image.md`), 8c (`docs/modules/image-processes.md`)
and 9a (`docs/modules/shells.md`). The as-built doc replaces this file.

## Why

Module 8b built two compilers that agree on every method of the image
but could not change the image: the Smalltalk compiler compiles and
compares, nothing installs, so there is no `Compiler evaluate:`, no
`Behavior>>compile:`, and module 9b's development protocol (remote
compile and install, the developer UI, an agent editing a running image)
has nothing to call. 8b also took two provisional shortcuts the owner
overturned: temps of inlined loop bodies share one temp vector across
iterations, and there are no class variables. This module settles all
three.

## What it hides

- How a method compiled in Smalltalk becomes a CompiledMethod the VM
  trusts: the one bytecode verifier (8a) runs on it, the literal frame is
  read-only, the install happens in the install stop with the method
  cache flushed, exactly as the image build's install does.
- The temp-vector rule for inlined loop bodies, in both compilers.
- Class variables: their binding objects, their lookup, their place in
  the Tonel files and the image.
- The release flag: how an image says it must not be changed from
  Smalltalk, and how the VM enforces it.

## 1. Per-iteration temp vectors (Pharo's rule)

Today (8b, Deviations): a temp declared inside an inlined loop body
(`to:do:`, `whileTrue:`, `whileFalse:`, `timesRepeat:`, `to:by:do:`) that
a real block captures and that is assigned lives in the enclosing real
scope's temp vector, shared by every iteration; the loop counter alone is
copied per iteration. A block created in iteration 3 therefore sees the
last iteration's value later.

Build Pharo's rule: a temp declared inside an inlined loop body that is
captured and assigned gets a **fresh temp vector per iteration**: the
`push_new_array` that makes it runs inside the loop, at the start of the
body, and the body's closures copy that vector. Temps declared outside the
loop keep one vector (they are the method's or the enclosing real block's
and must be shared, since the loop assigns them for the code after it).
Nested inlined loops: each level allocates its own. Inlined conditionals
(`ifTrue:` family, `ifNil:` family, `and:`/`or:`) are not loops and
allocate nothing of their own; their temps belong to the enclosing scope
as today. The loop counter stays as it is (copied per iteration; it
cannot be assigned).

Both compilers (`Sources/KajoCompiler/Compiler.swift` and `kernel/`'s
Compiler, CompilerScope, BytecodeGenerator) get the rule, and
`CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid` must still show
every method of the image matching. A kernel test forks blocks from
successive iterations that assign a body temp and checks each sees its
own value (the case that fails today); a bootstrap compiler test checks
the instructions: one `push_new_array` inside the loop, none for a loop
whose body temps are not captured, none for a loop with no body temps.
Measure: `just bench` A/B against the starting commit (aligned builds,
5 interleaved runs, 1 and 8 workers) and the Smalltalk kernels' golden
checksums (`just golden`) unchanged; a loop whose captured body temp is
assigned now allocates per iteration, which is the semantics, not a
regression; say so in the doc with a measured cost for one such loop.

## 2. Class variables

Smalltalk-80 class variables: declared on the class, shared by the class,
its metaclass and every subclass (and their metaclasses), named with a
capital. Build them:

- **Tonel**: the `#classVars : [ 'Name', ... ]` key, refused today
  (`Tonel.swift`), is accepted; `kajo build-image` refuses a name that
  shadows an instance variable, a temp, an argument or another class
  variable in the inheritance chain, and a lowercase name.
- **The binding**: a class variable is a `Binding` object (key Symbol,
  value) held by its class (a class-pool IdentityDictionary or an Array
  of bindings; decide and document; the Class format grows a slot, which
  is a kernel layout change, so the image builder, the loaders' class
  checks and the sealed-class rules are updated together). The method's
  literal frame holds the Binding; the frame is read-only, the Binding is
  not: a read is `push_literal` then `slot 2`-style access, a store a
  store into the Binding's value slot. Choose the bytecodes from set v1
  (ADR 0009) without adding one unless nothing fits; if one must be
  added, it goes in the `ext` space with the verifier, kasm, both
  compilers and the ADR's "Built (8d)" note updated. Bindings are
  ordinary objects for the collectors (nothing to do) and for the
  snapshot (saved with their class).
- **Lookup order** in both compilers: temps and arguments, instance
  variables, class variables (own class, then superclasses), then
  classes (globals). A class-side method sees the same class variables.
- **Reflection**: `Behavior>>classVarNames`, `classVariableNamed:`,
  `classPool`, the Binding in `Smalltalk at:`-style access
  (`Class>>bindingOf:`), and the recorded source still round-trips
  (Tonel out of the image where 8b writes it).
- Convert nothing that works: the kernel's class-side instance variables
  stay as they are (Transcript, Ephemeron, Smalltalk, PragmaIndex). One
  kernel class may gain a class variable where it is clearly right, with
  tests; the point is the mechanism, not a sweep.

Tests: a class variable read and written from instance and class side,
seen by a subclass, not seen by an unrelated class; a shadowing name
refused; the binding survives a snapshot round-trip and a `become:` of
its value; the Smalltalk compiler compiles the same bytecodes as the
bootstrap for every method using one.

## 3. Installing from Smalltalk

The owner: "allow installing from smalltalk, maybe leave a flag of some
kind to prevent it on release images (tbd)".

### The primitives

- **Make a method** (new primitive; pick the number in the kernel
  primitives' range and record it in ADR 0009's table): from a
  `CompiledCode` (bytecodes ByteArray, literals Array with block methods
  as CompiledCode and pragmas as PragmaLiteral, counts, primitive, flags,
  copied values) answer a CompiledMethod. The VM builds the object the
  way `Image.installKernelMethods` does (shared code, not a copy): it
  runs the **one bytecode verifier** on the bytecodes with the method's
  counts, recursively on block methods, refuses anything the verifier
  refuses (answer a failure the kernel turns into a `CompileError`, with
  the verifier's reason), marks the method, its block methods and the
  literal frame read-only, and interns literals as the image build does
  (Symbols through the symbol table, the floats and strings read-only).
  The bytecodes are **copied** into the method: the ByteArray the
  compiler handed over is the compiler's to change afterwards and must
  not alias a verified method's code.
- **Install** (new primitive): `(class, selector, method)` installs in
  the install stop (8a: method installation in a stop, method cache
  flushed, the relocation and marking states told as `installKernelMethods`
  tells them), replacing an existing method. The old method stays a valid
  object (frames may be running it; 8a's design already allows this,
  check that `Context` and the saved-Process loader (8c) agree: a saved
  frame of a method no longer in any dictionary must still load and
  verify, since the method itself is intact).
- **Remove** (new primitive): `(class, selector)` removes in the same
  stop.
- **Run without installing**: `CompiledMethod>>valueWithReceiver:arguments:`
  (new primitive, or `perform:` on a method object if the dispatch path
  allows it without touching `interpret`'s hot path; measure) runs a
  made method once. This is what `Compiler evaluate:` uses: compile the
  source as a method on the receiver's class (a *doit*: no selector,
  temps as the method's), run it, drop it. Nothing is installed by an
  evaluate.

### What stays sealed

AGENTS.md's rule: Class, Method and MethodDict are sealed from Smalltalk
(no primitive writes, creation or become; no ivar access in their
methods) or a verified method's bytecodes could be rewritten. The install
primitives keep that invariant: they are the only way a method enters a
class, they go through the verifier, and the method they make is
read-only before any other Process can see it. **Installing into a sealed
class is refused** by the primitives in this module (Class, Metaclass,
CompiledMethod, MethodDictionary and whatever else `om.isSealed` names);
their methods change only through the image build. The owner can lift
this later; record it as an open question.

A method that accesses instance variables of a sealed class (the
compiler's own check today) is refused by the make-method primitive too,
not only by the compiler: the primitive is the trust boundary, the
compiler is not.

### The release flag

An image can be marked **release**: in a release image the make, install
and remove primitives fail (the kernel signals an `InstallForbidden`
error naming the class and selector) and `Compiler evaluate:` fails the
same way; everything else runs unchanged. Provisional form, the owner
will decide the final one ("tbd"):

- The flag lives in the image header (bump the format version to 3;
  versions 1 and 2 still load as non-release) or in a special object the
  loader reads; **not** writable from Smalltalk by any primitive. The
  loader reports it; `Smalltalk isReleaseImage` answers it (a primitive
  read).
- `kajo build-image --release` sets it; `kajo seal <in> <out>` sets it on
  an existing image (a load, a flag, a save); nothing clears it (a
  release image is rebuilt from sources, not unsealed).
- `kajo test` and `kajo run` accept both kinds; the shells (9a) show the
  kind in their telemetry.
- A test installs in a development image, fails to install in the same
  image sealed, and checks a sealed image's loader report.

### The compiler in Smalltalk becomes the live one

`Behavior>>compile:` (source, optional category) compiles with the
Smalltalk compiler, makes and installs, records the source where 8b
records sources, and updates the pragma index (8b: the index is saved in
the image and kept by installation, so an install must maintain it:
`<primitive:>`, `<unwind>`, `<handler>`, `<mainThread>`, `<devProtocol>`
and user pragmas); `Behavior>>removeSelector:`; `Compiler evaluate:`
and `evaluate:for:` (receiver); `Object>>respondsTo:` and friends see the
change. The bootstrap compiler stays as the image build's compiler and
the oracle (`CompilerTest` keeps comparing). The test harness gains a
test that compiles a new method into a test class at run time, calls it,
replaces it, calls it again, removes it, and sees `doesNotUnderstand:`.

The method-for-method comparison now has a stronger form: a test
recompiles every method of the image with the Smalltalk compiler,
**makes** each one (the primitive, not installing), and checks `matches:`
against the installed method and that the verifier accepted every one.

## 4. Fuzzing the trust boundary

The make-method primitive takes untrusted input from Smalltalk, so it
gets the same treatment as the loaders: a kernel test feeds it 1500
seeded mutations of real CompiledCode (bytes flipped, literals swapped
for wrong classes, counts off by one, block methods with the wrong copied
count, a literal frame holding a Binding where a Symbol is expected) and
asserts each is refused or runs without a crash; and `fuzz-syntax`
(8b's target) gains a mode that compiles its input with the bootstrap
compiler, hands the result through the same Swift path the primitive
uses, and runs the method once. Every refusal is a reason the kernel
can show; every acceptance is a method the verifier passed.

## Rules

AGENTS.md binds the build; the usual ones that matter most here:

- Zero ARC on hot paths and one jump table in `interpret`
  (`just arc-check`). The new primitives are not hot paths; the
  per-iteration temp vector changes generated code, so the kernels' A/B
  must stay within noise (the kernels' loops have no captured body
  temps; verify by reading their bytecodes, and say so).
- `.strictMemorySafety()`; count the unsafe constructs in the doc.
- Tests assert on work, never on wall-clock time; the
  `underThreadSanitizer` switch for inflated bounds.
- Every gate green on the final commit, output in files; the kasm,
  snapshot and syntax fuzz targets and `just apps` (9a) included.
- Models: if the install stop's interaction with the save hold (8c) or
  the relocation state needs a new cross-thread protocol, model it first
  under `models/`; if the existing install stop covers it, say why in
  the doc.
- Do not edit AGENTS.md or docs/PLAN.md.

## Deliverables

- The code above with tests; the kernel's own tests extended.
- `docs/modules/kernel-live.md` replaced by the as-built doc in the
  style of `docs/modules/kernel-image.md` (what it hides, each part as
  built, measurements, changes to earlier modules, deviations from this
  brief with reasons, tests, broken variants run by hand, unsafe
  surface, hot-path check, not done, open questions for the owner,
  gates, commands).
- ADR 0009: a "Built (8d)" note (the new primitives in the table, the
  temp-vector rule, class variable bindings, any bytecode added).
- `docs/modules/kernel-image.md`: the Deviations and Not done entries
  this module closes marked as closed with a pointer here.
- `docs/CONTEXT.md`: Binding, release image, doit, and any other new
  term.
- Open questions for the owner: the final form of the release flag;
  whether installs into sealed classes should ever be allowed; whether
  `Process>>terminate` running ensure blocks and a frame restart (8b's
  Not done) belong in 9b or earlier.
