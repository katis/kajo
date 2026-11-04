# Module 8e: live classes (defining, reshaping and writing out classes from Smalltalk)

Status: built, 2026-11-04, from the brief written the same day from module
8d's Not done list (`docs/modules/kernel-live.md`) and what module 9b will
need underneath it. New: `Sources/KajoVM/ObjectModel/LiveClasses.swift`
(primitives 145 to 149: define, redefine, remove, write a file, read a
file; the running-frame rule; the stubs), `Sources/KajoVM/Loader/ClassRules.swift`
(the class rules the image build and the primitives share), module 1's
two-phase reshape (`prepareReshape`, `commitReshape` in
`ObjectMemory/Reshape.swift`), `kajo run --sources` and `kajo test
--sources` (`Headless.Options.sourcesDirectory`, `VMConfig.sourcesDirectory`);
in the kernel `ClassDefinition`, `ClassBuilder`, `ClassDefinitionError`,
`TonelWriter`, `TonelReader`, `TonelDocument`, `TonelLoader`, the
Smalltalk-80 class definition protocol on `Class` and `ClassDescription`,
method categories and the organization readers on `Behavior`, undeclared
Bindings, `Smalltalk writeTonel:` and `readTonel:`. `kernel/` is rewritten
once to the canonical Tonel form (its own commit). Changes to 8a, 8b and
8d below. Tests in `Tests/KajoCompilerTests/` (`LiveClassTests`,
`ReshapeMeasureTests`, `TonelRoundTripTests`, a new
`SnapshotScenarioTests` case) and in `kernel/` (`OrganizationTest`,
`LiveClassTest`, `TonelTest`, `ClassFuzzTest`).

## What it hides

- How a class comes to exist, changes shape or goes in a running image:
  three primitives in the install stop, the checks they repeat (the image
  build's own code), what happens to the instances (module 1's reshape,
  all or nothing across a class and its subclasses), to the methods
  (made again from their recorded sources against the new shape, the old
  ones forwarded to the new or to a stub), to a running frame (the change
  is refused) and to a removed class variable (its Binding stays,
  undeclared).
- Where a class's definition, a method's category and a class comment
  live in the image (`ClassDefinition`, per class; categories per class
  and side by selector, in `Smalltalk`).
- What "the same" means between a file and the image: the canonical Tonel
  form the writer in Smalltalk writes, which `kernel/` now is byte for
  byte.

## 1. Defining and removing classes

### The define primitive (145)

`Smalltalk primDefineClass: anArray` (`LiveClasses.swift`, `defineClass`)
takes the specification `ClassBuilder` builds:

| | |
|--:|---|
| 1 | the name, a Symbol |
| 2 | the superclass |
| 3 | every instance variable name, inherited first (Symbols) |
| 4 | every class-side instance variable name, inherited first |
| 5 | the class variables the class declares |
| 6 | the format kind (`fixed`, `variable`, `bytes`, `words16`, `words32`, `words64`, `weak`, `ephemeron`; Tonel's `#type` resolved) |
| 7 | the class of the pool's Bindings (nil without class variables) |
| 8, 9 | how many of 3 and of 4 are the superclass's |

In one stop it checks, each refusal a String naming the class and the
reason, which the kernel signals as a **ClassDefinitionError**:

- the name a Symbol, an identifier beginning with a capital, not
  `AnObsolete...`, not the name of a class in the class table;
- the superclass a registered class (not a metaclass, not a removed
  class), its named slots and class-side instance variables exactly the
  counts 8 and 9 claim (the inherited names are the kernel's, their
  number is the VM's);
- the format from the kind and the slot count (`KernelClassDefinition.format`,
  the image build's), and then, with the image build's code
  (`ClassRules`): at least the superclass's slots on both sides
  (`sizeProblem`), no subclass of a sealed class, no pointers under
  bytes (`subclassProblem`), every name an identifier and unique along
  the chain on each side, class variables capitalized, declared once
  along the chain (the superclasses' pools are read from their Bindings'
  keys) and shadowing no instance variable (`namesProblem`, which `Plan`
  in KajoCompiler now calls for the build, with the build's messages);
- the Bindings' class a fixed, unsealed class of at least two slots;
- room in the class table (`LoaderLimits.maxClassIndex`).

Then everything is allocated before the class table changes (the pool and
its Bindings, the metaclass object; a full heap refuses with the table as
it was), the class and metaclass registered (two new indices, as the
build gives), the class object allocated (the registration taken back if
the heap fills there, `unregisterLastClasses`), both pinned for good and
filled as the build fills them (superclass, empty method dictionary,
name, instance size, index; the metaclass under the superclass's
metaclass, with its pool). The answer is the class. The kernel records its
`ClassDefinition`; the name table rebuilds when it misses.

The existing stop covers it: nothing reads a class the primitive makes
until it answers; the class table and the format table are appended while
every other participant, the marker and the young collector included, is
parked; and nothing caches their storage across a stop (a scavenge caches
the format table's base for its own duration, and scavenges never
interleave with a stop). No model change.

### The Smalltalk-80 protocol

`Object subclass: #Foo instanceVariableNames: 'a b' classVariableNames:
'Count' category: 'Cat'` and the family on `Class` (`subclass:`,
`...package:`, `variableSubclass:...`, `byteSubclass:...`,
`weakSubclass:...`, `...category:kind:`) go to `ClassBuilder
define:superclass:instanceVariableNames:classVariableNames:classInstanceVariableNames:category:kind:comment:`,
which the Tonel loader uses too. A name already bound to a class of the
same superclass and kind is a **redefinition** (section 2), keeping the
class-side instance variables when the message names none. Another
superclass, or another format kind, is refused (Not done).

### Removing (147)

`Smalltalk removeClass: aClass` (`ClassBuilder remove:`) refuses, in the
kernel, a class with subclasses, then sends `primRemoveClass:as:`, which
in one stop, after module 4's promote-all, refuses a sealed or well-known
class, a subclass in the table, an instance, a method outside the class
whose literal frame (literal Arrays, Pragma arguments and block methods
included) names the class (classes are literals by identity: 8b's
compilers put the class object in the frame), a frame running one of its
methods (the running-frame rule, section 2), and another Process holding
the class on its stack (it may be about to make an instance). Instances
and literal references are counted again after a full collection when the
first count finds any, so garbage does not refuse. Then both method
dictionaries and the pool are emptied (the pool's Bindings are
forgotten: only the class's own methods could name them), the class is
renamed `AnObsolete<Name>` and cut from the hierarchy (superclass nil, its
metaclass under Class); the kernel forgets its definition, sources,
categories and undeclared Bindings, and the pragma index drops its
methods. The class object stays in the class table: an index is never
reused, the image loader needs no rule for a hole, and an image keeps the
removed class (`Behavior>>isObsolete`; `Smalltalk allClasses` leaves it
out).

## 2. Changing a class's shape

### The redefine primitive (146)

`Smalltalk primRedefine: anArray`, built by `ClassBuilder
redefine:instanceVariableNames:classVariableNames:classInstanceVariableNames:methods:`:

| | |
|--:|---|
| 1 shapes | each `{behavior. new named slots. layout}`: per new slot, the old slot (1-based) it takes, or 0 for nil. A metaclass's shape is its class object's (the class layout's five slots first, unmoved) |
| 2 methods | each `{behavior. CompiledCodes}`: the behavior's whole new method dictionary, made against its new shape |
| 3 pools | each `{class. Bindings}`: the class's new pool |
| 4 | a unary selector the stubs send (below), or nil |

The kernel computes every layout **by name** (`instanceVariableNamesOf:`
before, the new names after: a kept name keeps its value wherever it
moves, a new one is nil, a removed one is dropped), for the class and
every subclass (a subclass's inherited slots are the prefix), on the side
that changes, and compiles every method of each of those behaviors from
its recorded source with the compiler in Smalltalk against the new names
(`Compiler compile:in:instanceVariableNames:bindings:`, which also sees
the class variables about to be added). A method that does not compile
refuses the whole change before the primitive, naming every such method
(`LiveClassTest>>testARemovalThatBreaksAMethodChangesNothing`).

In one stop the VM then, before anything changes:

1. checks every shape (an open behavior, `installTarget`'s rule; a
   pointers format; a layout that takes each old slot at most once and
   names no slot past the old ones), every class in the table against its
   superclass with the new counts (a method of a class runs on its
   subclasses' instances, so they need its slots: the verifier's bound),
   and that every subclass of a class whose slot count changes is
   reshaped with it;
2. applies the **running-frame rule** (below);
3. runs module 4's promote-all (nothing young, no sweep pending, before
   it scans the heap);
4. makes every new method with 8d's make (`makeMethod`, the shared
   `makeMethodObjects`, the one bytecode verifier) against the behavior's
   format **to be** (`verifyHeapMethod`'s new `format:`), and refuses the
   whole change on the first refusal, naming the method;
5. pairs each method of the old dictionary with the new method of its
   selector, and their block methods pairwise in literal order when each
   pair has the same arguments, copied values and home flag
   (`pairMethods`);
6. pairs every other method of a reshaped class still in the heap (a
   removed method, an earlier version a closure or a Context holds, garbage
   not swept) with a **stub**: a method of the same class, selector,
   arguments, temps, copied values and flags whose body sends the kernel's
   selector (`methodRemovedByRedefinition`, which signals an error naming
   the class) to its receiver (`makeStub`, verified like any made method);
7. checks every pool (Bindings: fixed, unsealed objects with a Symbol
   key; the names by `namesProblem`);
8. allocates the new method dictionaries, the pool Arrays (read-only), and
   every new instance body (`prepareReshape`, module 1's checks for every
   class at once: no byte, read-only or frame-pinned instance; class
   objects, pinned for good, are moved like any other in the stop:
   nothing holds a raw pointer into a class body).

Then, with no failure possible: every old method is forwarded to its pair
in one `becomeForward` (every reference in the heap, the root registry and
the class table: closures, Contexts, Pragmas, the kernel's tables), the
instances are repointed to their new bodies (`commitReshape`), the formats
and the class objects' instance sizes set, the dictionaries and pools
stored, and module 1's verifier runs. Every lookup cache is flushed when
its worker sees the stop, the redefining worker's at once.

Afterwards the kernel brings its records along: the definitions, the
sources (their tables were keyed by the old methods, which are now the new
ones under another identity hash: rebuilt per behavior), the categories,
the pragma index (rebuilt), the Bindings.

Why forwarding: the old methods' slot indices are the old layout's. A
closure made by an old method and kept somewhere would otherwise run old
code on a reshaped receiver, reading the wrong slots or, after a slot was
removed, slots that are gone; and the image loader requires every method
in the heap to fit its class (8a), so an image saved after the change
would not load. Forwarded, a closure of a replaced method runs the
replacement's block (`LiveClassTest>>testOldClosuresFollowTheirMethod`:
the block reads the variable's new slot), a closure of a removed method
says so. Forwarding needs the running-frame rule: a stack is not in the
heap and is not rewritten, and a frame's saved pc does not fit the new
bytecodes.

### The running-frame rule

A class is not reshaped, and not removed, while any frame of any Process
runs one of its methods (a block method included). The stop scans every
word of every live Process's stack (`[0, sp]`, the running ones through
their worker's saved registers, as the collector's roots do) and the
running registers, under the scheduler lock, for a CompiledMethod of a
class the change touches. A frame's method is its header word, so every
frame is seen; a method held as a temp or an operand is seen too and
refuses as well (conservative; the kernel's own redefinition code keeps
methods in collections, never on its stack at the primitive). The refusal
names the Process and the method ("the Process 12 runs
LiveClassSample>>waitOn:then:, a method of a class being reshaped: try
again when it has left"; `LiveClassTest>>testARunningMethodRefusesTheReshape`:
a Process waits inside a method of the class, the reshape is refused, the
Process finishes with its old answer, the reshape then succeeds).

Why refuse rather than let the frame read the old layout: the frame would
read and write the receiver's slots by the old indices, which after a
reshape name other variables or lie past the end of the object, and its
method is forwarded away. The check runs in the stop that makes the
change, so no Process can enter a method of the class between the check
and the change; the developer tries again when the Process has left. 8c's
saved Processes are covered by the same rule: an image is saved from a
running system whose frames passed it at every change, and the saved-frame
rules check every frame against its method on load.

### Class variables

Adding a class variable makes a new Binding (or declares again one that
was removed from the same class, which methods compiled before may hold)
and replaces the pool; nothing is recompiled: new methods bind to the new
Binding. Removing one replaces the pool and makes the Binding
**undeclared**: the methods that hold it keep it, a read answers nil, a
write signals an error naming it (`Binding>>value:`; Binding gained an
`undeclared` slot), a new method that names it does not compile; the
kernel keeps it per class (`Smalltalk noteUndeclared:in:`), and adding the
variable again declares that same Binding, so those methods work again
without a recompile (`LiveClassTest>>testClassVariablesComeAndGoUndeclared`).
`addClassVarNamed:` and `removeClassVarNamed:` on Class.

### The protocol

`instanceVariableNames:` (on a class: its own instance variables; on a
metaclass: its class-side ones), `addInstVarName:`, `removeInstVarName:`,
`instVarNames`, `addClassVarNamed:`, `removeClassVarNamed:`, and a
`subclass:...` message naming an existing class all reach `ClassBuilder
redefine:...`. Sealed classes refuse (`installTarget`), as for 8d's
installs. `LiveClassTest` (9): define, instantiate, compile, refuse a
removal while an instance lives, remove, define the name again; 12
definitions the kernel or the VM refuses (a lowercase or obsolete name, an
existing class under another superclass, a sealed superclass, an
inherited name declared again, a name twice, a lowercase class variable,
one shadowing an instance variable or a superclass's, named slots or
pointers under bytes) and six specifications only the VM sees; a reshape
that reorders and adds slots in a class and its subclass, values kept by
name, every method recompiled, new instances of the new shape; a removal
that breaks methods refused naming them; class-side instance variables;
class variables undeclared and declared again; the running-frame rule;
old closures; a release image refusing all of it (`LiveInstallTests` runs
it sealed).

## 3. Categories and comments in the image

The image build hands every class definition over before the kernel's
initialization (`Smalltalk recordDefinitions:`: name, superclass, own
instance variables, own class-side instance variables, category, format
kind, comment, one String per class) and every method's category with its
source (`recordSources:`, "Class[ class]\nselector\ncategory\nsource").
8b's synthesized `Smalltalk class >> kernelDefinitions` is gone: the
compiler in Smalltalk reads instance variable names from the
`ClassDefinition`s, which the class definition protocol keeps current,
and every method of the image now has a Tonel source.

Categories are kept per class and side by selector (`Smalltalk
noteCategory:of:in:`): `compile:classified:` files under the category it
names, `compile:` under the replaced method's or `as yet unclassified`,
`removeSelector:` forgets it, a redefinition keeps them (or takes the
file's). Read by `Behavior>>categoryOf:`, `organization` (category to
sorted selectors), `categories`, `selectorsInCategory:`. The class comment
and category: `ClassDescription>>comment`, `comment:`, `category`,
`category:`. `OrganizationTest` (4): every method of the image has a
category, the files' categories, the class's category and comment,
`compile:classified:`; the byte-identical round trip checks every
category of the kernel too.

## 4. Tonel: the writer, the canonical form, the reader

### The writer (`TonelWriter`, `Class>>tonelSource`)

The canonical form: the class comment in double quotes (a quote doubled),
`Class {`, the keys `#name`, `#superclass`, `#instVars`, `#classVars`,
`#classInstVars` (each only when not empty, one name per line),
`#category` and `#type` (only when the format kind differs from the one
the superclass gives, Tonel's inheritance rule), a tab before each key and
two before each name; then every method: instance side before class side,
grouped by category with the categories sorted, selectors sorted in each,
each as an empty line, `{ #category : ... }` and `Class >> pattern
[body]`. A STON symbol is bare when every scalar is an ASCII letter or
digit, quoted otherwise. Pattern and body are the recorded source split
after the message pattern (`Scanner class >> patternEndIn:`). The image
build records a method's source as the pattern without the blanks before
the bracket, followed by the body between the brackets (a blank between
them when the body starts with neither a blank nor a line break), so the
writer puts both brackets back where they were. A body that does not
start on a line of its own (a method compiled at run time, `compile:
'foo ^ 1'`) is put on one, indented by a tab, and ends with a line break;
anything else is written as recorded (Deviations: indentation).

`Smalltalk writeTonel: aDirectory` writes every class but the removed
ones, sealed classes too, as `<Name>.class.st` through the write primitive
(`TonelWriter write:into:`); `writeAllTonel` into the opened directory
itself. The image does not record which methods came from an `Extension`:
everything is in the class's file (Deviations). A file larger than one
String (32 760 bytes) cannot be written; the largest kernel file,
Compiler, is 27 KB.

### The canonical commit

The image built from `kernel/` wrote 124 of its 147 files differently,
every difference either the order of the methods or SmallInteger's
redundant `#type : #normal` (checked by splitting each file into its
header and its methods and comparing them as sets). `kernel/` was
replaced by what the image wrote, in its own commit (`e29bcb5`); a
throwaway check built `Plan` from the files before and after and
compared every compiled method (bytecodes, literals, counts, primitive,
flags, pragmas, blocks recursively), every recorded source and every
class definition record: 1674 methods and 147 classes, none differ. Since
then `TonelRoundTripTests>>theKernelWrittenOutIsTheKernelByteForByte`
builds the image from `kernel/`, writes every class into a fresh
directory through the file primitives, and asserts that the set of files
is `kernel/`'s and that every file is byte-identical to the one it was
built from. Every later kernel change in this module was written out by
the image and copied back.

### The reader (`TonelReader`, `TonelDocument`, `TonelLoader`)

`TonelReader read: aString` is the bootstrap reader in Smalltalk, rule for
rule (the comment with doubled quotes, which the Swift reader now reads
too; the STON subset; the method's `{ #category }` metadata; the body's
end by bracket depth outside strings, comments and character literals;
the same recorded source). `TonelRoundTripTests>>theTwoReadersReadEveryKernelFileAlike`
reads every kernel file and the fixture with both and compares name,
superclass, the three name lists, category, type, comment, kind and every
method's side, category and source: all alike. `TonelTest` (4) reads back
what the writer wrote for nine classes (definition, comment, each method's
source and category), checks the writer's form, and refuses eight
malformed files with a CompileError.

`Smalltalk readTonel: aString` (`TonelLoader load:`): a new class is
defined, an existing one (same superclass and kind) redefined, and in
both cases the file's methods become the class's whole method set on both
sides in the same redefine primitive call (`ClassBuilder redefine:...
methods:`), made against the file's shape: a file that renames an
instance variable together with the methods that use it loads in one
step, and a method the file lacks goes (an Extension's methods are
compiled into their class one by one). `TonelTest>>testAClassDefinedAndRedefinedFromTonel`
reads a class from text, writes it back to the same text, reads it again
(nothing changes), then reads a version with a renamed instance
variable, two changed methods and one method fewer: the instance made
before keeps its other value, the methods use the new slot, the removed
method is gone, and the class writes the new text back.
`TonelRoundTripTests>>aClassWrittenOutOfOneImageReadsBackIntoAnother`
writes a fixture class (instance, class and class-side instance
variables, a variable format, a class variable, literals of every kind,
blocks, both sides) and two kernel classes out of an image the bootstrap
compiler built, reads the three texts into a fresh kernel image with the
reader and the compiler in Smalltalk, gets the same texts back, saves and
loads that image with every loader check, and finds the fixture's methods
identical to the first image's, bytecode for bytecode.

### The file primitives (148, 149)

`Smalltalk primWriteFile: aPath contents: aString` (replace or create, by
writing beside the file and renaming over it) and `primReadFile: aPath`
(UTF-8 text, at most one String) take a path **relative to the directory
the host opened the VM with**: `kajo run --sources <dir>`, `kajo test
--sources <dir>`, `Headless.Options.sourcesDirectory`, which `ShellVM`
reads through `Headless.configs` (the shells pass none yet). Refused: no
directory (none given, or no VM), a release image, an absolute path, an
empty, `.` or `..` component, a NUL, a parent directory that does not
exist or that resolves (`realpath`, through symbolic links) outside the
directory, a path that is not a String. No directory is made, nothing is
listed or removed: nothing else of a file system
(`LiveClassTests>>theFilePrimitivesStayInTheirDirectory`: eleven paths,
among them a symbolic link inside the directory pointing out of it, and a
release image).

## Fuzzing the trust boundary

`ClassFuzzTest>>testSeededSpecificationsAreRefusedOrAccepted` (kernel,
slow): 1500 mutations, seeded (an LCG), of six specifications the define
primitive accepts (fixed with both kinds of variables and a class
variable, a subclass of OrderedCollection, variable, bytes, weak with
class variables, ephemeron): an element swapped for one of 25 strangers
(integers, a String, nil, true, a Float, a Character, Symbols, classes, a
metaclass, Arrays, a LargeInteger, a Semaphore, a Process, a Context, a
BlockClosure, a CompiledMethod, a ByteArray, a Binding), an inherited
count off by one, a name twice, a name missing, another kind (or an
unknown one), a sealed or odd superclass (CompiledMethod, Context,
Metaclass, a metaclass, ByteArray, Float, SmallInteger, Array, Process,
Semaphore, String, Symbol, WeakArray, Ephemeron, Binding), a bad class
name, a bad class variable, a stranger for the Bindings' class, the Array
cut or grown. Each is refused with the VM's reason or accepted; an
accepted class makes an instance, writes and reads a slot, compiles and
runs a method, and is removed. One run: 1168 refused (102 distinct
reasons), 332 accepted, each exercised and removed.
`testSeededReshapesAreRefusedOrAccepted`: 500 mutations of a reshape of a
class with five instances through the redefine primitive (a stranger for
the behavior or for any part, the slot count off, a layout naming no slot
or one twice, a method set of non-CompiledCode, a pool of non-Bindings, a
metaclass shape): 395 refused, 105 accepted, every instance intact after
each.

The snapshot fuzzer's seed corpus gains `live-class.img`
(`LiveClassTests>>aClassDefinedAndReshapedAtRunTimeSavesAndLoads`, written
with `KAJO_WRITE_FUZZ_SEEDS=1`): a small image (no kernel) in which the
primitives defined a class with a class variable and three instances,
reshaped it (slots reordered and added, its pool replaced, its class side
given an instance variable), defined and removed a second class, driven
directly with the specifications ClassBuilder would send; saved, it
passes every loader rule and keeps every value where the layouts put it.
The kernel scenario `SnapshotScenarios redefinedClass` does the same
through the kernel's protocol with a closure, a class variable and a
class-side instance variable, saves the image with its Processes, and the
resumed image answers from the reshaped instances (39).

## Models

None changed. Every structural change of this module happens in the
install stop of 8a and 8d (`stopWorld`, every participant parked, the
lookup caches flushed by the stop's epoch): the define primitive appends
to the class and format tables and allocates in the stop, as the make
primitive and the intern of a Symbol do; the redefine primitive is module
1's reshape and become, which have always run in a stop, preceded by
checks that read the stacks as the collector's roots do (under the
scheduler lock, running Processes through their workers' saved
registers); the file primitives touch no shared VM state. No new thread
interaction, wait or flag; the save hold (8c) composes as with any stop (a
save holds the scheduler, then stops; a redefinition waiting for its stop
parks like any stopper).

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS 27,
swift.org Swift 6.4.2, 2026-11-04.

### The kernels against the starting commit

The starting commit's `kajo` (6bef327, from a worktree) against this
module's (0255675, the same code as d3f0a41), both built `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
`--slice-ms 0`, 12:48 to 12:52 (load average 5.8 falling to 2.5
1-minute, a build had just ended); median (min to max) ms. The Smalltalk
kernels run from images each binary built from its own `kernel/`. Every
checksum is the published one on both sides.

| kernel | workers | 6bef327 ms | 8e ms | 8e / start | checksum |
|---|--:|--:|--:|--:|---|
| fib | 1 | 1696.8 (1695 to 1704) | 1695.9 (1693 to 1710) | **0.999** | 24682992 |
| fib | 8 | 228.6 (224 to 231) | 218.4 (218 to 224) | **0.955** | 24682992 |
| arith | 1 | 2549.0 (2546 to 2552) | 2536.2 (2532 to 2545) | **0.995** | 372800000 |
| arith | 8 | 355.9 (344 to 360) | 337.0 (336 to 343) | **0.947** | 372800000 |
| sends | 1 | 2578.1 (2566 to 2587) | 2576.0 (2563 to 2587) | **0.999** | 1066666666666668 |
| sends | 8 | 353.9 (339 to 361) | 331.6 (331 to 334) | **0.937** | 133333335000001 |
| ivars | 1 | 1971.6 (1969 to 1974) | 1970.3 (1966 to 1972) | **0.999** | 36383626 |
| ivars | 8 | 270.6 (268 to 279) | 262.9 (257 to 265) | **0.972** | 71714128 |
| storeheavy | 1 | 2395.7 (2394 to 2407) | 2412.2 (2407 to 2416) | **1.007** | 512000 |
| storeheavy | 8 | 309.2 (308 to 313) | 326.1 (322 to 334) | **1.055** | 512000 |
| alloc | 1 | 2930.6 (2929 to 2937) | 2937.3 (2930 to 2940) | **1.002** | 41950911 |
| alloc | 8 | 477.5 (444 to 486) | 490.9 (462 to 510) | **1.028** | 42008248 |
| Smalltalk sends | 1 | 2264.2 (2262 to 2272) | 2278.0 (2271 to 2323) | **1.006** | 1066666666666668 |
| Smalltalk sends | 8 | 303.1 (298 to 308) | 298.4 (290 to 302) | **0.984** | 133333335000001 |
| Smalltalk ivars | 1 | 1970.6 (1968 to 1973) | 1966.3 (1964 to 1970) | **0.998** | 36383626 |
| Smalltalk ivars | 8 | 273.5 (267 to 279) | 259.6 (255 to 264) | **0.949** | 71714128 |
| Smalltalk closures | 1 | 3839.8 (3830 to 3849) | 3810.9 (3796 to 3816) | **0.992** | 210210000 |
| Smalltalk closures | 8 | 502.0 (492 to 508) | 504.1 (500 to 516) | **1.004** | 209214000 |

- One worker: 0.992 to 1.007.
- Eight workers: 0.937 to 1.055, both ways (fib, arith, sends, ivars and
  the Smalltalk ivars faster, storeheavy and alloc slower, as in 8d's
  A/B, which saw storeheavy at 1.055 too), within the runs' spread.
  `interpret` is the same code in both aligned binaries: its disassembly
  (1321 lines) differs only in the page offsets of the jump table's
  `adrp` (8 diff lines). Nothing of this module is on the paths the
  kernels take: the new primitives are reached through `primitive`'s
  switch, and six counters follow 8d's in the interpreter's counters.

### The reshape's stop

`ReshapeMeasureTests` (`Fixtures/measure/ReshapeMeasure.class.st`): a class
of three instance variables and 50 methods, 10 000 instances held in five
Arrays, given an instance variable in the middle (`instanceVariableNames:
'a z b c'`) on a two-worker VM with the default collectors; the release
build of `just test-release`'s scratch path, five runs (load average
1.5 to 2.0):

| | median (min to max) |
|---|--:|
| the whole change (the 50 methods compiled in Smalltalk, the stop, the kernel's records) | 10.8 ms (10.8 to 11.5) |
| the longest install stop (the redefine's) | 1.04 ms (1.03 to 1.14) |

The stop makes and verifies the 50 methods, scans the stacks, the heap's
CompiledMethods (for the old versions) and its entries (for the
instances), allocates and copies 10 000 bodies and forwards 50 methods
(one pass over every slot of the heap: module 1's `becomeForward`). A debug
build takes 490 ms and 193 ms. Every instance keeps its values by name and
every method runs recompiled (asserted).

### The image and the tests

The kernel image is 4.27 MB with 1737 methods and 152 classes (3.10 MB,
1577 and 145 with the `sends` kernel at 8d's end): the class definitions,
categories and comments now in the image, the Tonel writer and reader,
ClassBuilder, the tests. `kajo test` runs the 179 kernel tests in 45 s of a
debug build (`ClassFuzzTest` takes 5.5 s of it; the byte-identical round
trip takes 2.5 s as a Swift test).

## Changes to earlier modules

- **Module 1**: `reshape` is `prepareReshape` (the checks and every new
  body allocated, for several classes at once, `allowPinned` for class
  objects) and `commitReshape` (cannot fail); the one-class `reshape`
  calls both. `ObjectMemory.unregisterLastClasses`.
- **8a**: `verifyHeapMethod` takes a `format:` to verify against (a
  redefinition's shape to be). Primitives 145 to 149. Counters
  `classesDefined`, `classesRedefined`, `classesRemoved`,
  `classChangesRefused`, `filesWritten`, `filesRead`.
- **8b**: a method's recorded source is its pattern and body without the
  bracket (8b replaced the `[` with a blank, so a source held the blanks
  before the bracket and one more); the Tonel reader takes a doubled
  quote in a comment; `recordSources:` carries the category;
  `recordDefinitions:` replaces the synthesized `kernelDefinitions`
  method; the build's class checks are `ClassRules` (the same messages).
  `Smalltalk initializeKernel` runs the class-side `initialize` methods
  superclasses first by depth, then by name (`classesSuperclassesFirst`).
  `kernel/` is in the canonical form.
- **8d**: `makeMethod` takes a `format:` and reports the block methods it
  made; `Behavior>>compile:` keeps a category, `compile:classified:` the
  one it names; the compiler in Smalltalk compiles against given instance
  variable names and pending Bindings. Binding has a third slot
  (`undeclared`).
- **9a**: none in the code; `ShellVM` honours `sourcesDirectory`.
- The CLI: `--sources` for `kajo run` and `kajo test`.

## Deviations from the brief

- **Removing a class keeps its class object** in the class table, renamed
  `AnObsolete<Name>` and cut from the hierarchy, instead of freeing its
  index: the image loader requires every index to name a class, and a
  stray reference can still name the object.
- **Old methods of a reshaped class are forwarded**, not left to run their
  old code: the brief accepted "the old method object stays valid" for a
  running frame, which the running-frame rule refuses; for the methods no
  frame runs (closures, Contexts, earlier versions), forwarding to the
  recompiled method or to a stub keeps the loader's rule that every
  method fits its class, which a reshape would otherwise break.
- **The running-frame rule is conservative**: a CompiledMethod of the
  class anywhere on a stack refuses, not only a frame's method.
- **Redefining with another superclass, or another format kind, is
  refused** (Not done; the brief allowed refusing the former).
- **Indentation is not normalized** beyond putting a one-line body on a
  line of its own: re-indenting the lines of a multi-line source would
  change String literals and comments that span lines. Every kernel method
  is indented with tabs already.
- **No Extensions are written**: the image does not record where a method
  came from; the benchmark kernels' extensions of UndefinedObject would be
  written into its file.
- **The file primitives make no directory** and read and write whole files
  of at most one String (32 760 bytes).
- **A Tonel file is the whole class** when read: a method of the class the
  file lacks is removed (the brief said "installing every method").

## Tests

Swift: 312 `KajoVMTests` (as at the start) and 54 `KajoCompilerTests`
(Swift Testing's count, parameterized tests once; 46 at the start): new
`LiveClassTests` (2), `ReshapeMeasureTests` (1), `TonelRoundTripTests` (3),
the `redefinedClass` case of `SnapshotScenarioTests`' parameterized test;
`KernelImageTests` runs the kernel's tests.

Smalltalk: 179 kernel tests (`kajo test`; 160 at the start): new
`OrganizationTest` (4), `LiveClassTest` (9), `TonelTest` (4),
`ClassFuzzTest` (2).

## Broken variants run by hand

| rule | broken variant | test | result |
|---|---|---|---|
| a running frame refuses a reshape | the redefine primitive skips `runningMethod` | `LiveClassTest>>testARunningMethodRefusesTheReshape` | fails: the reshape is accepted while the Process waits inside `waitOn:then:` (no ClassDefinitionError); its frame's method word now names the forwarded, freed entry, which is why the rule is not a test switch in the suite (`tearDown` then reports "LiveClassSample has instances": the waiting Process holds one) |
| replaced methods are forwarded | the redefine primitive skips `becomeForward` | `LiveClassTest>>testOldClosuresFollowTheirMethod` | fails: "Assertion failed": the old closure reads the old slot index, now the new variable `z` (nil), instead of `a` (9) |
| the make verifies against the shape to be | `makeMethod` given no `format:` (the class's current format) | `LiveClassTest>>testReshapeKeepsValuesByNameAndRecompiles` | errors: "LiveClassSample>>a:b:: pc 2: instance variable 2 outside 0..<2": a recompiled method that uses the moved slot is refused against the old shape |
| the define primitive re-checks the names | `defineClass` skips `ClassRules.namesProblem` | `LiveClassTest>>testDefinitionsTheVMRefuses` | fails: "Expected ClassDefinitionError to be signaled" (a name declared twice along the chain is accepted: only the VM checks names) |
| the file primitives stay in their directory | `sourcesPath` drops the resolved-parent check | `LiveClassTests>>theFilePrimitivesStayInTheirDirectory` | fails twice: `run` answers -7 (the write through a link out of the directory succeeded) and the escaped file exists outside the directory |

## Unsafe surface

`Sources/KajoVM` lines with `unsafe` (comments excluded): 4589, against
4543 at the start (6bef327): `LiveClasses.swift` 44 (the counters 4, the
stop and its epoch 4, the worker's allocation context 2, the stack scans of
the running-frame rule and of the removal under the scheduler lock 21, the
VM's configuration for the sources directory 1, `realpath` 3, the file
reads and writes 9), `Roots.swift` 2 (`unregisterLastClasses`).
`Reshape.swift` keeps its 3, `ClassRules.swift` and `KajoCompiler` have
none. Counted on the final commit's clean build (0 warnings).

## Hot-path check

`just arc-check` on the final code: 135 functions, zero
`swift_retain`/`swift_release`; `interpret` 1056 instructions (as at the
start), one jump table. Nothing of this module is on the checked paths:
primitives 145 to 149 are reached through `primitive`'s switch (one call
to `liveClassPrimitive`, out of line), and `VMConfig` gained a String
(`sourcesDirectory`) that only the file primitives read, by member.

## Not done

- Redefining a class with another superclass or another format kind.
- Freeing a removed class's indices; the class object stays.
- Extensions in the written files; normalizing the indentation of
  multi-line sources.
- Directories and listings in the file primitives; files larger than one
  String. A symbolic link as the last path component: the parent is
  resolved through links and must stay under the directory, but a link
  named by the last component is followed by the read primitive (a write
  replaces the link itself), so a link planted in the directory can be
  read through.
- A reshape while a frame runs a method of the class (refused by rule).
- Non-class globals (8b, 8d).
- `Process>>terminate` running unwind blocks; a frame restart (8b's; 8d's
  open question 3).
- Compile warnings as events (8b, agreed, not built here).

## Open questions for the owner

1. **Redefining with a new superclass**: here or in 9b? Provisional:
   refused with a ClassDefinitionError. It would fall out of the redefine
   primitive (the superclass slot changes in the stop; the layouts are
   already by name) once the kernel computes a layout across two chains
   and the VM checks the new chain for cycles; not built within this
   module.
2. **The file primitives' directory rule for the shells**: one directory
   the host opens, paths relative to it, no way out through links, no
   directory made. On iOS the natural directory is the app's container
   (or a folder the user picks, whose access is security-scoped); on
   macOS the project directory. Is one directory per VM right, or should
   the host open several (sources, images, exports)?
3. **The running-frame rule**: refusing is safe and simple, but a
   long-running Process (an event loop) inside a method of the class
   blocks every reshape of it until it leaves. Should the debugger (9b)
   be able to unwind such frames to a point outside the class, or restart
   them after the change, as Pharo's restart does?
4. **Obsolete classes** stay in the class table and the image forever.
   Should a removal free the indices once no object names the class (a
   collection can tell), with a loader rule for a hole?
5. **A host-side save after a VM ran with nurseries**: a test of this
   module first saved an image on the host (`Image.saveImage`) after a VM
   with the default nursery configuration had run on it, and module 1's
   verifier trapped ("free entry ... is in no free list"); the same happens
   on the starting commit with any kernel method. The image build and every
   existing test save through the VM's own save or after a VM without
   nurseries, so nothing in the product reaches it; the tests here run
   without nurseries for that reason. Worth a look by whoever next touches
   the VM's teardown.

## Gates

The code and this doc but for this table and the hot-path paragraph are
d3f0a41's; every gate ran on d3f0a41, Mac mini (M2 Pro), swift.org 6.4.2,
2026-11-04 12:54 to 14:54, every output in a file, each step logged with
the commit it ran on:

| gate | result |
|---|---|
| `swift test` | 312 + 54 passed, 218 + 55 s |
| under load (12 busy loops) | 312 + 54 passed, 254 + 67 s |
| ThreadSanitizer | 312 + 54 passed, 0 reports, 616 + 1461 s |
| ThreadSanitizer under load | 312 + 54 passed, 0 reports, 664 + 1617 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release in 135 functions, `interpret` 1056 instructions, one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 312 + 54 passed |
| `just model-check` | 28 + 5 + 15 passed |
| `just soak` | passed: 1000 seeds under every configuration, no failing seed; the snapshot modes saving 762 to 980 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.44 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 3.64 million runs (the `live-class.img` seed in the corpus), no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 1.20 million runs, no crash |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| clean build | exit 0, 0 errors, 0 warnings |

(312 is `KajoVMTests`, 54 `KajoCompilerTests`, whose kernel-image suite
runs the kernel's 179 SUnit tests.) The clean build took 10 s from an
empty scratch path (the toolchain's compilation cache); `just ios-check`
typechecks every KajoVM file with strict memory safety from nothing and
reports no warning either.

## Commands

```zsh
kajo test --sources /tmp/out                     # the file primitives opened on /tmp/out
kajo run kernel.img --sources src                # Smalltalk writeTonel: 'kernel' writes src/kernel/*.class.st
swift test --filter TonelRoundTripTests          # the byte-identical round trip, both readers, image to image
swift run kajo test --filter ClassFuzzTest       # the 1500 + 500 mutations
KAJO_WRITE_FUZZ_SEEDS=1 swift test --filter aClassDefinedAndReshapedAtRunTimeSavesAndLoads
swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests --filter aClassOfTenThousandInstancesAndFiftyMethodsIsReshaped
```
