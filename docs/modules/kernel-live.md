# Module 8d: live compilation (per-iteration temp vectors, class variables, installing from Smalltalk)

Status: built, 2026-11-04, from the brief written the same day from the
owner's answers to module 8b's open questions 1, 2 and 4
(`docs/modules/kernel-image.md`). New:
`Sources/KajoVM/ObjectModel/LiveMethods.swift` (primitives 143 and 144,
the sealed-class rule for installs, the CompiledCode reader),
`Sources/KajoVM/Loader/MethodBuilding.swift` (a method's heap objects, one
way for the image build and for the make primitive), primitive 85 in
`Interpreter/Special.swift`, the release flag in the image header, `kajo
seal` and `kajo build-image --release`, the syntax fuzzer's make-and-run
mode (`FuzzEntry.makeAndRun`); in the kernel `Binding`, `InstallForbidden`,
`Behavior>>compile:`, `removeSelector:` that forgets the source, `Compiler
evaluate:`, class variables in both compilers, `Float`'s non-finite
constants as class variables. Changes to 8a, 8b and 9a below. Tests in
`Tests/KajoCompilerTests/` (`ClassVariableTests`, `LiveInstallTests`, new
cases in `CompilerTests` and `SnapshotScenarioTests`) and in `kernel/`
(`ClassVariableTest`, `LiveCompileTest`, `MakeFuzzTest`, two new
`BlockClosureTest` cases, with the samples `ClassVariableSample`,
`ClassVariableSampleChild`, `LiveSample`, `MakeFuzzSample`).

## What it hides

- How a method compiled in Smalltalk becomes a CompiledMethod the VM
  trusts: what the make primitive reads, that it reads it in a stop, that
  it builds the objects with the image build's code and runs the one
  bytecode verifier on what it built, which objects end read-only and
  pinned.
- The temp-vector rule for inlined loop bodies, in both compilers.
- Class variables: the Binding, the pool in the metaclass, the bytecodes
  a read and a write compile to, the build's checks.
- The release flag: where it lives, who sets it, what it refuses.

## 1. Per-iteration temp vectors

Both compilers (`Sources/KajoCompiler/Compiler.swift`'s header has the
rule; `kernel/Compiler.class.st`, `CompilerScope.class.st`,
`TempVariable.class.st`):

- An inlined block of a loop is a **loop scope**: both blocks of
  `whileTrue:` and `whileFalse:`, the receiver of `whileTrue`,
  `whileFalse` and `repeat`, the block of `to:do:`, `to:by:do:` and
  `timesRepeat:`. It takes a sequence number when it is entered, before its
  argument and temps, as a real scope does.
- A variable's **owner** is the nearest enclosing scope that is real or a
  loop scope; an inlined conditional (`ifTrue:` family, `ifNil:` family,
  `and:`, `or:`) owns nothing, so a temp it declares inside a loop body
  belongs to that body and is per iteration too. A captured and assigned
  variable lives in its owner's vector (`Variable.owner`,
  `TempVariable>>owner`); a closure copies the owner's vector
  (`.vector(owner)`, keyed by the owner's sequence number).
- A loop scope with vector variables gets a frame temp of the enclosing
  real scope, placed among that scope's locals at the loop's sequence
  number; its body begins with `push_new_array n`, `store_temp k` on every
  pass (`genInlinedBody`), after the loop's test.
- The loop counter of `to:do:` is as before: copied per iteration, never
  assigned by the program. Temps of the method (or of the enclosing real
  block) keep one vector, made once at entry.

Checked by `aLoopBodysCapturedAssignedTempGetsAVectorPerIteration` (one
`push_new_array` right after the loop's `jump_if_false`, nested loops two,
a conditional's temp inside a loop the body's, `whileTrue:` and
`timesRepeat:`) and `loopsWithoutCapturedAssignedBodyTempsMakeNoVector`
(uncaptured body temps, captured but unassigned ones, no body temps, the
method's own vector made once), and in Smalltalk by
`BlockClosureTest>>testLoopBodyTempsArePerIteration` (blocks from three
iterations of `to:do:`, `whileTrue:` and `timesRepeat:` with a conditional,
each with its own value, twice) and `testLoopTempsSharedByTheBodysProcesses`
(eight forked blocks each squaring its own iteration's temp). Both fail
with the old rule (Broken variants). `CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid`
still finds every method of the image identical between the compilers.

No method of the kernel and none of the benchmark kernels has a captured
and assigned loop-body temp: a build with a probe in `genInlinedBody`
(removed) reported only the two new `BlockClosureTest` methods, for the
kernel and each of `Fixtures/smalltalk/{sends,ivars,closures}`. Their
bytecodes are unchanged; the A/B below is the check.

## 2. Class variables

**Tonel**: `#classVars : [ 'Name', ... ]` (refused in 8b) is read for
classes (not extensions). The build (`Plan` in `KernelBuilder.swift`)
refuses, each with its own message (`theBuildRefusesBadClassVariables`
checks them): a name that does not begin with a capital; one declared
twice; one a superclass already declares; one equal to an instance
variable or class-side instance variable of the class or a superclass; a
subclass's instance variable or class-side instance variable of that
name; a pool without a class `Binding`. A temp, a method or block
argument of that name is refused by both compilers wherever the variable
is visible ("'Count' shadows A's class variable").

**The binding** (the brief left the form open): a class's pool is a
read-only Array of the kernel's `Binding` objects (key Symbol, value), in
a new slot of the class's **metaclass** (`MetaclassLayout.classPool`,
slot 6; Metaclass is fixed 7). The metaclass, because a class and its
class side share it and because the class layout stays as it was: every
class-side instance variable keeps its slot, and the compilers, kasm and
the loader's class-side rules needed no change. The VM never reads the
pool; the loader checks only that it is nil or a read-only Array. The
image build makes the pools after defining the classes
(`Image.defineClassPool`); `Literal.binding(owner:name:)` resolves to the
pool's Binding when a method is made.

**Bytecodes** (no new one; ADR 0009's Built (8d)): read `push_literal B;
value` (the special send, whose tier finds no closure and sends `value`,
which Binding answers); write `push_literal B; <value>; value:` (special
`value1`; `Binding>>value:` answers its argument, the assignment's value),
then `pop` when the value is not used. The Binding is in the literal
frame, which is read-only, so a method cannot be made to name another
variable; the Binding itself is an ordinary object (the collectors need
nothing; the snapshot saves it with its pool).

**Lookup**: temps and arguments, instance variables, class variables
(the class's own, then its superclasses'; the class side the same), then
classes. The Smalltalk compiler asks `theClass bindingOf:`, the bootstrap
compiler a table per class the build computed (`Plan.classVariables`).

**Reflection** (`kernel/Behavior.class.st`): `classPoolBindings` (the
Array), `classVarNames` (Symbols), `classPool` (a new IdentityDictionary
name to Binding, the class's own), `classVariableNamed:` and `bindingOf:`
(own or inherited, from either side; nil otherwise),
`classVariableOwnerOf:`. `Smalltalk kernelDefinitions` gains a seventh
element per class, its class variable names. There is no Tonel writer in
the image (8b records sources; it writes no Tonel): the round trip that
exists, recorded sources recompiled to the same methods, holds for every
method that names a class variable (CompilerTest).

**In the kernel**: `Float` keeps `Infinity`, `NegativeInfinity` and `NaN`
in class variables set by `Float class>>initialize` (which the build
runs), `infinity`, `negativeInfinity` and `nan` answering them (computed
once instead of on every call). The class-side instance variables
(Transcript, Ephemeron, Smalltalk, PragmaIndex) stay.

**Tests**: `ClassVariableTests` (the listing of a read, a write for
effect and for value, one literal for both; the run of instance side,
class side and subclass methods sharing it; an unrelated class refused;
the refusals above; the pool in the metaclass with the very Binding in
each method's literal frame, a run-time value saved and loaded with it; a
`become:` of the value seen through the Binding) and the kernel's
`ClassVariableTest` (both sides and a subclass, an unrelated class and
its class side refused by the Smalltalk compiler, the shadowing refusals,
reflection, the literal is the Binding and the Smalltalk compiler makes
the same method, `become:`).

## 3. Installing from Smalltalk

### The primitives (`ObjectModel/LiveMethods.swift`, `Interpreter/Special.swift`)

| # | selector | what |
|--:|---|---|
| 143 | `CompiledCode primMakeMethodIn: aBehavior` | the compiler's output made into a CompiledMethod of aBehavior, or a String saying why not; fails in a release image |
| 85 | `CompiledMethod valueWithReceiver: anObject arguments: anArray` | the method run once, not installed (an activation primitive) |
| 97 | `Behavior primAddSelector:withMethod:` (8a) | now refused for a sealed class and in a release image |
| 98 | `Behavior primRemoveSelector:` (8a) | the same |
| 144 | `Smalltalk isReleaseImage` | the header's flag |

**Make (143).** The receiver is a CompiledCode (the kernel's class: nine
slots, `CompiledCodeLayout`); any literal of the receiver's class is a
block method's code, any Pragma a pragma (the compiler in Smalltalk now
emits Pragmas without a method; `PragmaLiteral` is gone). In one stop
(`stopWorld`, as `Machine.intern` makes a Symbol):

1. `CodeReader` reads the graph into `MethodParts`: the counts
   SmallIntegers in 0..2^20, the block flag set exactly on block methods,
   a block method with a nil selector and named once in the whole graph,
   bytecodes a ByteArray (copied out), literals an Array of at most 4095
   (copied out); literal kinds: immediates, nil, true, false, Symbols and
   classes as they are; Strings and ByteArrays copied; a boxed Float of 8
   bytes copied (one a SmallFloat can hold becomes that); a LargeInteger
   copied when normalized (no high zero byte, outside SmallInteger's
   range); literal Arrays copied element by element (only literal kinds
   inside, 2^16 elements in all, 64 deep); Pragmas made afresh (selector a
   Symbol of the arguments' arity); an instance of a sealed class refused;
   any other object kept as it is (that is how a Binding enters). At most
   4096 block methods, 64 deep.
2. `makeMethodObjects` (shared with the image build) makes the
   CompiledMethod and its block methods: bytecodes and literal Arrays
   pinned for good and read-only, the method objects pinned and read-only,
   copied literals pinned and read-only, Pragmas read-only with their
   method set. Old-space allocation in the worker's context with the
   stop's roots and every object made so far as extra roots.
3. `verifyHeapMethod`, the image loader's check, on the method (for the
   class) and on each block method (as a block of the class): the header,
   the selector's arity, the instance-variable range (none for a sealed
   class, the class-side ones for a metaclass), the bytecode verifier's
   trace and `maxStack`. Any refusal makes the answer the reason; the
   objects made are garbage.

The kernel's `CompiledCode>>makeMethodIn:` signals a CompileError with the
reason; the primitive's fallback signals InstallForbidden in a release
image. A method that names an instance variable its class does not have,
a sealed class's included, is refused here, not only by the compiler
(`testMakeVerifiesAndCopies`: compiled for LiveSample, made for Object).

Why the existing stop covers it (the brief's model rule): the make is an
allocation in a stop like the intern of a Symbol (module 8b), and the
install is 8a's install stop unchanged. Nothing new crosses threads: the
objects are made, pinned and marked while every other worker is parked,
and no other Process can reach them until the primitive answers. The save
hold (8c) composes as with any stop: a save holds the scheduler, then
stops; a make waiting for its stop parks like any stopper (`retry:
true`). No model change.

**Install and remove (97, 98)**: as 8a built them (the method compiled for
this class under this selector, verified again, the dictionary replaced in
a stop, every cache flushed), now first `installTarget`: never in a
release image, never for a sealed class. A metaclass is always sealed (its
instances are classes), so the rule is the class the methods are for:
`Foo class` takes class-side methods unless Foo itself is sealed. So
CompiledMethod, MethodDictionary, Metaclass, Class, Behavior,
ClassDescription, Process, Semaphore, BlockClosure, Context and their
class sides change only through the image build (`testSealedClassesStayClosed`).

**Run once (85)**: `[method receiver array]` becomes `[receiver a1 ... an]`
and the method is activated as a send would (`activate`). Refused (the
primitive fails) unless the method is a CompiledMethod, not a block, with
no primitive (an activation runs bytecodes only; a method of only a
primitive has none), taking as many arguments as the Array holds, and the
receiver's class is the method's class or inherits from it, so the
instance variables are those the verifier allowed (`runsOnce`, out of
line). Every CompiledMethod in the heap was verified: the loader, the
image build and primitive 143 are the only ways one is made (the class is
sealed). Not `perform:` on the method: the activation primitives are
already outside `interpret`, and 85 joins them there.

A frame of a replaced or removed method keeps running it: the method is
an ordinary object the frame holds. The saved-Process loader (8c) checks a
saved frame's method against the method table, which is every
CompiledMethod in the heap, not the dictionaries, so it loads and verifies
too: `SnapshotScenarios removedMethod` saves an image while a Process
waits inside a method compiled at run time, replaced and removed, and the
resumed Process finishes in the old method.

### What stays sealed

AGENTS.md's rule holds: the only way a method enters a class is 97 after
143, both verified, and the method is read-only before any other Process
can see it. Installing into a sealed class is refused (above; open
question 2). Making a method of a sealed class is allowed (a doit's
receiver may be one, `Compiler evaluate: '...' for: Object`, whose class
is a metaclass), and the verifier gives it no instance variables.

### The release flag

Provisional form (open question 1): image format 3 has a **flags word**
(header word 5); bit 0 marks a **release image**, every other bit must be
zero. The loader reads it into the object memory
(`ObjectMemory.isReleaseImage`, set before any VM runs, never written
afterwards and by no primitive); every save writes it back. `kajo
build-image --release` sets it at the build, `kajo seal <in> <out>` on an
existing image (a load with every check, the flag, a save; it keeps saved
Processes); nothing clears it. In a release image 143, 97 and 98 fail and
the kernel signals **InstallForbidden** naming the class and selector
(`compile:`, `addSelector:withMethod:`, `removeSelector:`, `makeMethodIn:`
and `Compiler evaluate:` check `Smalltalk isReleaseImage` first, so the
pragma index and the sources are never touched). Everything else runs
unchanged: `kajo test` runs a release image (and says so on stderr),
`kajo run` reports `image=release` or `image=development`, `Headless`
answers `isReleaseImage(bytes)` without loading, and the shells add
`image=` to every result line's telemetry (`Telemetry.imageKind`,
`ShellVM.isReleaseImage`).

### The compiler in Smalltalk becomes the live one

`Behavior>>compile: aString` compiles with the Smalltalk compiler, makes
the method (143), installs it through `addSelector:withMethod:` (97, the
pragma index kept as 8b keeps it), records the source (`Smalltalk
noteSource:of:`) and forgets the replaced method's; `compile:classified:`
takes a category it does not keep (methods have no categories in the
image). `removeSelector:` forgets the source too. `Compiler evaluate:
aString` and `evaluate:for:` compile a **doit**: the method `DoIt` of the
receiver's class whose body is the source (its temporaries the method's,
the last statement's value answered, nil for an empty one;
`Compiler class>>compileDoIt:in:`), make it, run it with 85, drop it;
nothing is installed (`testEvaluate`: `UndefinedObject` and `Array` have
no `DoIt` afterwards). `respondsTo:` and the lookup see installs at once
(the install stop flushes every cache). The bootstrap compiler stays the
image build's compiler and the oracle.

`LiveCompileTest` (kernel): compile a method into `LiveSample`, call it,
replace it, call it again, read its source, remove it and see
`doesNotUnderstand:`; instance variables, blocks and a class-side method;
the pragma index with a run-time pragma, before and after removal; doits;
make verifies and copies (the method, its bytecodes, its literal frame and
literals read-only; changing the compiler's ByteArray afterwards changes
nothing; a flipped byte refused with the verifier's "no instruction at
offset"; an instance variable outside the class; a Binding where a send's
selector was); run once and its refusals; sealed classes closed; the
release flag (a development image runs a doit; a release image refuses
every way in with InstallForbidden). And the stronger comparison,
`testEveryMethodMakesAsInstalled` (slow): every method of the image
compiled by the Smalltalk compiler, made by 143 (verified, not
installed), `matches:` the installed method and has its bytecodes and
literal count: every one (1577 in the kernel) passes.

`LiveInstallTests` (Swift) runs LiveCompileTest in the development image,
seals the same image (`Headless.seal`), checks the flag in the header and
in the loader, that a load and save keeps it, runs
`testTheReleaseFlag` and ClassVariableTest in the sealed image, the run
report's `image=` for both kinds, an unknown flag bit refused, and
`KernelBuild` with `release`.

## 4. Fuzzing the trust boundary

`MakeFuzzTest>>testSeededMutationsAreRefusedOrRun` (kernel, slow): 1500
mutations, seeded (an LCG), of the six `MakeFuzzSample` methods compiled
by the Smalltalk compiler (instance variables, `to:do:` with a captured
vector, closures, a non-local return, literals of every kind, a class
variable through a send, a `whileTrue:` loop vector). Each mutates a deep
copy, in the method or one of its block methods: a byte flipped; a
literal swapped for one of 24 strangers (integers, a String, nil, a Float,
a Character, Symbols of other arities, classes, a Binding, an Array, a
boxed Float, a LargeInteger, a sample instance, a Semaphore, a Process,
a Context, a BlockClosure, a CompiledMethod, an OrderedCollection, a
ByteArray, a Pragma); a count (arguments, temps, maxStack) off by one; a
block's copied count off by one; a Binding for a Symbol; a flag flipped;
a primitive set; the bytecodes truncated or extended; the selector,
bytecodes or literals replaced by a stranger; two literals swapped. Every
one is refused with the VM's reason (a CompileError) or made, read-only,
and run once in a Process of its own (errors caught, terminated after 200
yields if it has not ended). One run: 989 refused (63 distinct reasons),
511 made, all 511 ran to their end.

`fuzz-syntax`'s **make-and-run mode** (`FuzzEntry.makeAndRun`, called by
`FuzzSyntax.run` for every method source that compiles): the bootstrap
compiler's method is laid out as the Smalltalk compiler's CompiledCode in
a small image (`Image.codeObject`), made by primitive 143 through a kasm
method on a standalone interpreter (the same Swift path, no VM), checked
again with the verifier, and unless it loops (a backward jump in it or a
block: the standalone interpreter cannot preempt) run once through
primitive 85 with 3 for every argument, then the heap verifiers. A
refusal there would be a disagreement between the assembler and the
verifier; a trap a finding. `compiledMethodsAreMadeAndRunThroughThePrimitive`
covers it in the suite. Its first run found a bug as old as 8b (Changes).

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS 27,
swift.org Swift 6.4.2, 2026-11-04 07:14 to 07:18 (load average 3.1 to 3.8
1-minute, the agent session the busiest other process).

### The kernels against the starting commit

The starting commit's `kajo` (10e581a, from a worktree) against this
module's (c657344), both built `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
`--slice-ms 0`; median (min to max) ms. The Smalltalk kernels run from
images each binary built from its own `kernel/` (the start cannot read a
version 3 image). Every checksum is the published one on both sides.

| kernel | workers | 10e581a ms | 8d ms | 8d / start | checksum |
|---|--:|--:|--:|--:|---|
| fib | 1 | 1712.9 (1699 to 1728) | 1717.4 (1694 to 1723) | **1.003** | 24682992 |
| fib | 8 | 224.0 (221 to 237) | 220.6 (217 to 241) | **0.985** | 24682992 |
| arith | 1 | 2575.9 (2559 to 2598) | 2579.4 (2541 to 2596) | **1.001** | 372800000 |
| arith | 8 | 349.3 (342 to 359) | 337.7 (336 to 357) | **0.967** | 372800000 |
| sends | 1 | 2618.0 (2593 to 2630) | 2599.8 (2569 to 2620) | **0.993** | 1066666666666668 |
| sends | 8 | 358.5 (338 to 362) | 339.9 (334 to 344) | **0.948** | 133333335000001 |
| ivars | 1 | 2008.6 (1971 to 2011) | 1997.1 (1974 to 2008) | **0.994** | 36383626 |
| ivars | 8 | 258.2 (258 to 276) | 263.1 (256 to 277) | **1.019** | 71714128 |
| storeheavy | 1 | 2442.9 (2403 to 2452) | 2433.2 (2405 to 2440) | **0.996** | 512000 |
| storeheavy | 8 | 312.3 (308 to 336) | 329.5 (321 to 342) | **1.055** | 512000 |
| alloc | 1 | 3019.3 (2990 to 3036) | 2981.6 (2941 to 3045) | **0.988** | 41950911 |
| alloc | 8 | 493.1 (442 to 509) | 500.8 (452 to 519) | **1.016** | 42008248 |
| Smalltalk sends | 1 | 2292.5 (2255 to 2302) | 2313.5 (2289 to 2332) | **1.009** | 1066666666666668 |
| Smalltalk sends | 8 | 297.6 (292 to 313) | 309.1 (297 to 321) | **1.039** | 133333335000001 |
| Smalltalk ivars | 1 | 2004.2 (1976 to 2016) | 2009.1 (1968 to 2017) | **1.002** | 36383626 |
| Smalltalk ivars | 8 | 262.7 (256 to 279) | 255.8 (252 to 273) | **0.974** | 71714128 |
| Smalltalk closures | 1 | 3857.5 (3804 to 3868) | 3874.2 (3806 to 3889) | **1.004** | 210210000 |
| Smalltalk closures | 8 | 495.2 (484 to 521) | 512.7 (494 to 524) | **1.035** | 209214000 |

- One worker: 0.988 to 1.009.
- Eight workers: 0.948 to 1.055, both ways (sends and arith faster,
  storeheavy, the Smalltalk sends and closures slower), the runs' ranges
  overlapping in every row. `interpret` is the same code in both aligned
  binaries: its disassembly (1322 lines) differs only in the page offsets
  of the jump table's `adrp` (16 diff lines). What 8d adds to a running
  worker is nothing on the paths the kernels take: primitive 85's case in
  `activationPrimitive` (reached by no kernel), two counters after
  `methodsInstalled` in the interpreter's counters, and the kernels'
  bytecodes are unchanged (section 1).

### What a per-iteration vector costs

The same loop of 20 million iterations, each making a block that assigns
a temp and evaluating it, once with the temp declared in the loop body (a
fresh vector each pass, the new rule) and once declared in the method (one
vector): `1 to: 20000000 do: [:i | | t | t := i. blk := [t := t + 1]. sum
:= sum + blk value]`, one worker, the release `kajo` above, five runs
alternating: 1423.9 ms (1407 to 1542) against 1208.3 ms (1204 to 1212),
the same checksum: **10.8 ns per iteration**, one Array of one slot
allocated and stored in a frame temp, 1.18x on a loop that already makes
a closure per pass. This is the semantics (each closure keeps its own
variable), not a regression; no kernel method pays it.

### The image

The kernel image is 3.10 MB with 1577 methods and 145 classes (with the
`sends` kernel), against 2.73 MB, 1503 and 137 at the start: the new
classes and methods (the compiler's live side, the tests and their
samples) and their sources. `kajo build-image` takes 72 ms in release
(55 at the start). `LiveCompileTest>>testEveryMethodMakesAsInstalled`
makes all 1577 methods through primitive 143, one stop each, in about
13 s of a debug `kajo test` run, nearly all of it the compiler in
Smalltalk (CompilerTest's comparison alone takes 11 s).

## Changes to earlier modules

- **8a**: Metaclass objects are a slot larger (`MetaclassLayout.classPool`);
  image format 3 with the flags word; versions 1 and 2 are refused with a
  message that says to rebuild (images are never committed; the fuzz seeds
  `image.img`, `saved-states.img`, `saved-shapes.img` are rewritten and
  `class-pool.img` added, by `KAJO_WRITE_FUZZ_SEEDS=1`; the old crash
  fixtures stay as refusals). Primitives 97 and 98 refuse sealed classes
  and release images. `Image.makeMethod` builds through the shared
  `makeMethodObjects`, which also marks the method objects read-only
  (8a's left them writable, though no primitive wrote them). The loader
  checks the class pool's shape. Counters `methodsMade`, `methodsRefused`.
- **8b**: the compiler in Smalltalk emits Pragmas, not PragmaLiterals (the
  class is gone); the bootstrap parser refuses a chain of unary or binary
  sends longer than the nesting limit, 256 (found by this module's first
  `just fuzz syntax` run: a binary chain of thousands overflowed the Swift
  stack in code generation, a left-deep tree; ASan's stack-overflow,
  `Fixtures/syntax/crash-long-binary-chain.st`,
  `aMessageChainPastTheNestingLimitIsRefused`). **The sources table** held
  every method's source in one IdentityDictionary, whose Array cannot pass
  one block (4095 slots), so it could not grow past 1536 entries: with this
  module's methods the kernel reached 1550, `recordSources:` died in an
  unhandled error at the 1537th, and the build went on (`runToCompletion`
  read only VM errors), leaving 14 methods without a source (CompilerTest
  found it). Sources are now kept per class, and `runToCompletion` reports
  a Process that ended without an answer (how an unhandled error ends
  one), so such a build fails ("ended without an answer"). Any kernel
  collection of more than 1536 hashed entries has the same limit (8b's
  one-block objects); this was the only one that reached it.
- **8c**: none in the code; `SnapshotScenarios removedMethod` is new.
- **9a**: `ShellVM.isReleaseImage`, `Telemetry.imageKind` in every result
  line.
- The CLI: `kajo seal`, `kajo build-image --release`, `image=` in `kajo
  run`'s report.

## Deviations from the brief

- **No new install and remove primitives**: 8a's 97 and 98 already
  installed in the stop with every cache flushed and re-verified the
  method; they gained the sealed-class and release refusals. The make
  primitive (143) is new.
- **Versions 1 and 2 do not load** (the brief: "still load as
  non-release"): the class pool is a Metaclass slot, so their Metaclass
  objects are a slot short. Images are rebuilt from sources; nothing
  committed is an image the code needs.
- **The pool is in the metaclass**, not a new Class slot, so the class
  layout and every class-side instance variable index stay.
- **Installing into `Foo class`** is allowed: every metaclass is sealed,
  and refusing them would forbid class-side methods. The rule is the
  sealing of the class the methods are for.
- **The make primitive answers the refusal as a String** instead of
  failing, so the kernel's CompileError carries the verifier's reason; it
  fails (and the kernel signals InstallForbidden) only in a release image.
- **A doit has a selector**, `DoIt` (the verifier wants a selector of the
  argument count; nothing installs it).
- **Pragmas, not PragmaLiterals**, in the compiler's output, so the VM
  needs to know no kernel class but CompiledCode's layout.
- **The make-and-run fuzz mode runs no looping method**, and runs on a
  standalone interpreter without a VM: it cannot preempt.
- **No Tonel writer**: 8b writes none; the round trip is the recorded
  sources (CompilerTest).
- **`compile:classified:` keeps no category.**

## Tests

Swift: 310 `KajoVMTests` (as at the start; three new image corruptions
are cases of the parameterized `theImageLoaderRejects`: `aVersion2Image`,
`unknownFlags`, the bad version now 4) and 46 `KajoCompilerTests` (Swift
Testing's count, parameterized tests once; 41 at the start): new
`ClassVariableTests` (5), `LiveInstallTests` (3), in `CompilerTests` the
two temp-vector tests, `compiledMethodsAreMadeAndRunThroughThePrimitive`
and `aMessageChainPastTheNestingLimitIsRefused`, in `SnapshotScenarioTests`
the `removedMethod` case.

Smalltalk: 160 kernel tests (`kajo test`; 130 in 8c's count, 9a's view
tests between): new `ClassVariableTest` (6), `LiveCompileTest` (9),
`MakeFuzzTest` (2), `BlockClosureTest` (2).

## Broken variants run by hand

| rule | broken variant | test | result |
|---|---|---|---|
| a loop body's vector is per iteration | the loop scopes made ordinary inlined scopes (`isLoop: false`, the 8b rule) in the bootstrap compiler | `BlockClosureTest>>testLoopBodyTempsArePerIteration`, `testLoopTempsSharedByTheBodysProcesses` | both fail ("Assertion failed": the blocks share the last iteration's variable) |
| installs refuse sealed classes | `installTarget` answers the class index whatever its seal | `LiveCompileTest>>testSealedClassesStayClosed` | fails: "Expected Error to be signaled" (CompiledMethod took a method) |
| the make primitive verifies what it made | `verifyHeapMethod` skipped on the method and its blocks | `MakeFuzzTest` | the VM traps in the first mutations: "ObjectMemory.swift:208: Assertion failed" (a mutated method ran); a trapping variant, so run by hand only |
| a build step that ends in an unhandled error fails the build | the sources in one IdentityDictionary again (8b's table) | `kajo build-image` | refused: "Smalltalk recordSources: ended without an answer (an unhandled error: the Transcript shows it)"; before `runToCompletion`'s check the same build succeeded with 14 sources missing, which `CompilerTest` reported as "no source for Smalltalk class>>kernelDefinitions" |
| a message chain is held to the nesting limit | the starting commit's parser | `just fuzz syntax` | libFuzzer: "AddressSanitizer: stack-overflow" in `Compiler.gen` (254 frames shown), input `crash-long-binary-chain.st` |

## Unsafe surface

`Sources/KajoVM` lines with `unsafe` (comments excluded): 4449, against
4434 at the start (10e581a): `LiveMethods.swift` 6 (the worker and its VM
for the stop, the counters, the allocation context), `Special.swift` 136
to 143 (primitive 85's stack moves and `runsOnce`'s state),
`Generations.swift` 74 to 76 (the release flag's accessor).
`MethodBuilding.swift` and `KajoCompiler` have none. Counted on the final
commit's clean build (0 warnings).

## Hot-path check

`just arc-check` on the final code: zero `swift_retain`/`swift_release` on
every checked function, `interpret` 1056 instructions (as at the start),
one jump table. `activationPrimitive` (on the list) gained primitive 85's
case: raw stack moves and one out-of-line call (`runsOnce`); no ARC. The
make primitive is reached through `primitive`'s switch (one call) and is
not a hot path.

## Not done

- A Tonel writer (class definitions with `#classVars` out of the image).
- Method categories in the image; `compile:classified:` drops them.
- Adding or removing class variables at run time (the pool is made by the
  image build; the class objects are sealed).
- Non-class globals.
- `Process>>terminate` running unwind blocks; a frame restart (8b's; open
  question 3).
- The make-and-run fuzz mode does not run looping methods.
- Compile warnings as events (8b, agreed, not built here).

## Open questions for the owner

1. **The release flag's form.** Provisional: a header flag (format 3,
   word 5 bit 0), set by `kajo build-image --release` or `kajo seal`,
   never cleared, refusing make, install, remove and doits. Should a
   release image also drop the compiler classes, the sources, or the
   development pragmas?
2. **Installs into sealed classes.** Refused (and their class sides);
   `Foo class` of an ordinary class is allowed. Should the kernel's own
   sealed classes ever take methods from Smalltalk?
3. **`Process>>terminate` running ensure blocks, and a frame restart**
   (8b's Not done): in 9b with the debugger, or earlier?
4. **The parser's nesting limit** of 256 (brackets and now message
   chains) is deep enough for a debug build's code generation to overflow
   a 512 KB thread stack at about 100 (the test of the limit compiles a
   chain of 20). Lower the limit, or make code generation iterative for
   chains? **Built (follow-up, `docs/modules/reserve-and-depth.md`):
   both.** Chains are walked by loops (no limit but the method's size);
   brackets and blocks cost 4 to 9.5 KB of stack per level in a debug
   build and 0.4 to 1.6 KB in release, so the limit is 32 in both
   compilers, and the deepest input of every construct compiles on a
   512 KB thread in debug and release; the syntax fuzzer runs every input
   on a 512 KB thread.

## Gates

The code is c657344's; the gates ran on 9f0bda4 (this doc) and, from the
second ThreadSanitizer run on, on 62f85ed, which adds only the main
session's two notes in `docs/modules/shells.md`. Mac mini (M2 Pro),
swift.org 6.4.2, 2026-11-04 07:20 to 08:56, every output in a file, each
step logged with the commit it ran on:

| gate | result |
|---|---|
| `swift test` | 310 + 46 passed, 157 + 34 s |
| under load (12 busy loops) | 310 + 46 passed, 195 + 41 s |
| ThreadSanitizer | 310 + 46 passed, 0 reports, 552 + 909 s |
| ThreadSanitizer under load | 310 + 46 passed, 0 reports, 562 + 1070 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release, `interpret` 1056 instructions, one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 310 + 46 passed |
| `just model-check` | 28 + 5 + 15 passed |
| `just soak` | passed: 1000 seeds under every configuration, the snapshot modes saving 929 to 979 of 1000, no failing seed |
| `just fuzz kasm 600` | libFuzzer build ok, 2.53 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 3.44 million runs, no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 1.70 million runs (the make-and-run mode in each that compiled), no crash |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| clean build | exit 0, 0 errors, 0 warnings |

(310 is `KajoVMTests`, 46 `KajoCompilerTests`, whose kernel-image suite
runs the kernel's 160 SUnit tests.) Before the gates, a 60 s `just fuzz
syntax` on ef9eb47 found the message-chain stack overflow (Changes to
earlier modules), fixed in c657344, after which a 120 s run was clean.

## Commands

```zsh
kajo build-image --release -o rel.img          # a release image
kajo seal kernel.img sealed.img                 # mark an existing image
kajo test sealed.img --filter LiveCompileTest   # refusals with InstallForbidden
swift run kajo test --filter MakeFuzzTest       # the 1500 mutations
just fuzz syntax 600                            # the make-and-run mode included
KAJO_WRITE_FUZZ_SEEDS=1 swift test --filter 'savedProcessFuzzSeeds|mutatedImagesLoad|theBindingSurvives'
```
