# Module 8b: the kernel, the compiler, the image build, the test harness

Status: built, 2026-11-03. The Smalltalk side of module 8
(`docs/modules/kernel.md`, "8b, the Smalltalk side", "String", "Pragmas",
"Test harness and the event protocol", "Scope"). New: the bootstrap
compiler `Sources/KajoCompiler/` (Swift), the kernel `kernel/` (Tonel, one
file per class), `kajo build-image` and `kajo test`, the `fuzz-syntax`
target, the compiler in Smalltalk, and the benchmark kernels written in
Smalltalk (`Tests/KajoVMTests/Fixtures/smalltalk/`). Changes to module 8a
are listed below, among them the owner's two answers that 8b built: the
read-only failure is `modificationForbiddenAt:value:`, and the symbol table
is weak. Tests in `Tests/KajoCompilerTests/` (Swift) and in `kernel/` (the
kernel's SUnit tests, run by `kajo test` and by a Swift test).

Saved Processes in images are module 8c, next; nothing here assumes an
image cannot hold one (below, "The entry point").

## What it hides

- The Smalltalk grammar, the Tonel format and how a method's variables are
  laid out in a frame (which are copied into closures, which live in a temp
  vector, the order of the temps): `KajoCompiler` and the kernel's
  `Compiler`, which follow the same rules (`Compiler.swift`'s header).
- How the kernel's classes map onto the VM's well-known ones (which are
  re-parented, which are new) and how the image is put together, verified
  and initialized before it is saved.
- How the kernel signals, handles, resumes, retries and unwinds over the
  VM's frame walks.
- How events leave the VM (one primitive, one host hook) and how the CLI
  turns them into NDJSON, a summary and JUnit XML.

## The bootstrap compiler (`Sources/KajoCompiler/`)

| file | lines | what |
|---|--:|---|
| `Syntax.swift` | 861 | scanner, parse tree, recursive-descent parser |
| `Compiler.swift` | 806 | scopes and the capture analysis, code generation, inlined control flow |
| `Tonel.swift` | 307 | the Tonel reader (STON class header, method metadata, method bodies) |
| `KernelBuilder.swift` | 209 | the image build |
| `TestReport.swift` | 106 | the summary and JUnit XML from the event stream |
| `FuzzSyntax.swift` | 28 | the syntax fuzz entry |

The compiler emits the assembler's input, not bytes: `AsmMethod` (lines of
`.op`, `.pushLiteral`, `.send`, `.pushClosure`, `.jump`, `.label`, blocks
and pragmas), which KajoVM's `assemble` encodes (literal frame in first-use
order with duplicates merged, the `ext` prefix past 255, jump offsets) and
runs through the one bytecode verifier, as it does for kasm. kasm now lowers
to the same structure (`lower(KasmMethod)`), so there is one encoder and one
verifier for both. The compiler is not trusted: whatever it produces is
verified by the assembler at build time and again by the image loader.

**Grammar.** Smalltalk-80 method syntax with Pharo's pragmas (before or
after the temporaries) and brace arrays; literals: integers of any size,
radix (`16r1F`) and exponent (`2e3` an Integer, `1e-3` a Float), floats
(read by Swift's `Double(_:)`), `$c`, strings with `''`, symbols
(`#foo:bar:`, `#+`, `#'any'`), literal arrays with bare identifiers and
keywords as Symbols, byte arrays; a `-` right before a number is a negative
literal. No ScaledDecimal, no `_` assignment. Nesting deeper than 256 is a
`CompileError` (a hostile input cannot overflow the Swift stack).

**Variables and frames** (the rules both compilers follow exactly; the
kernel's `Compiler` comment points at them):

- A variable is *captured* when a real (not inlined) block other than the
  scope that declares it uses it. A captured variable that is ever
  assigned lives in its scope's temp vector; every other captured variable
  is copied into the closure. Arguments are never assigned.
- An inlined block's argument (the `to:do:` counter, the `ifNotNil:`
  argument) cannot be assigned by the program, and the inlined code's own
  writes do not count: captured, it is copied, so each closure keeps its
  iteration's value. (The first version counted the loop's increment as an
  assignment: ten Processes forked in `1 to: 10 do: [:i | [... i ...] fork]`
  all saw 11. `ProcessTest>>testManyProcessesWithASharedQueue` found it.)
- Every declaration gets a sequence number in source order; a real scope
  gets one when entered. A real scope's frame: its arguments; for a block,
  its copied values (outer variables and outer temp vectors, by sequence
  number); its temp vector, if any; its other locals (its temporaries,
  those of the blocks inlined into it, the hidden loop temps) in sequence
  order.
- Inlined when the arguments (and a loop's receiver) are literal blocks of
  the right arity: `ifTrue:`, `ifFalse:`, `ifTrue:ifFalse:`,
  `ifFalse:ifTrue:`, `and:`, `or:`, `ifNil:`, `ifNotNil:`,
  `ifNil:ifNotNil:`, `ifNotNil:ifNil:`, `whileTrue:`, `whileFalse:`,
  `whileTrue`, `whileFalse`, `repeat`, `to:do:`, `to:by:do:` (an integer
  step) and `timesRepeat:`. The `ifNil:` family is inlined too (ADR 0009
  lists only the Boolean ones): `isNil` is answered inline and cannot be
  overridden, so nothing is lost.
- The special selectors compile to their opcodes (never under `super`),
  integers in -128...127 to `push_int`, nil/true/false to their opcodes. A
  pure expression for effect (a literal, a variable, a block) emits nothing.
  A method without `^` ends in `return_self`; an empty block answers nil.

**Pragmas.** `<primitive: n>`, `<unwind>` and `<handler>` are the
compiler's own (they set the method header: the primitive, the unwind
mark for `ensure:`/`ifCurtailed:`, the handler mark for `on:do:`); every
other pragma is a `Pragma` literal (selector, arguments, method; read-only).
After compiling everything the build collects the selectors class-side
`<consumesPragmas: #(...)>` pragmas declare and warns, on stderr, for any
other pragma (`anUnconsumedPragmaWarns`: `<expectedFailur>` warns; the
kernel builds with none).

**Tonel.** `Class { #name, #superclass, #instVars, #classInstVars,
#category, #type }` then methods, each optionally preceded by `{ #category :
... }`; `Extension { #name : ... }` adds methods to a class defined
elsewhere. `#type` is `#normal` (fixed), `#variable`, `#bytes`, `#words`
(32-bit), `#words16`, `#words64`, `#weak`, `#ephemeron`; absent, the
superclass's kind is inherited (pointers-variable, bytes and word kinds;
weak becomes variable). `#classVars` are refused (below, Deviations).

## The kernel (`kernel/`)

123 class files, 10 600 lines, 1368 methods compiled (the build's count,
the synthesized `Smalltalk class >> kernelDefinitions` included), written
from scratch with Smalltalk-80 and ANSI selectors except String.

| area | classes |
|---|---|
| objects and classes | Object, Behavior, ClassDescription, Class, Metaclass, UndefinedObject, Boolean, True, False, Message, MethodDictionary, CompiledMethod, Pragma, PragmaIndex, Smalltalk |
| numbers | Magnitude, Number, Integer, SmallInteger, LargePositiveInteger, LargeNegativeInteger, Fraction, Float, SmallFloat |
| text | Character, String, Symbol, Utf8View |
| collections | Collection, SequenceableCollection, ArrayedCollection, Array, ByteArray, OrderedCollection, Interval, HashedCollection, Set, IdentitySet, Dictionary, IdentityDictionary, Association, WeakArray |
| streams | PositionableStream, ReadStream, WriteStream, ReadWriteStream |
| blocks and exceptions | BlockClosure, Context, Exception, ExceptionSet, Error, ZeroDivide, SubscriptOutOfBounds, NotFound, KeyNotFound, PrimitiveFailed, AssertionFailure, IllegalResumeAttempt, ModificationForbidden, MessageNotUnderstood, BlockCannotReturn, UnhandledError, Halt, Warning, Notification |
| processes | Process, ProcessorScheduler, Semaphore, Mutex, Monitor, SharedQueue, Delay, Ephemeron (and the finalization Process) |
| system | Transcript |
| compiler | Scanner, Parser, ParseNode and its subclasses (LiteralNode, VariableNode, AssignmentNode, MessageNode, CascadeNode, BraceNode, ReturnNode, BlockNode, MethodNode), TempVariable, CompilerScope, CompiledCode, PragmaLiteral, BytecodeGenerator, Compiler, CompileError |
| SUnit | TestCase, TestResult, TestSuite, TestFailure, TestRunner |
| tests | 24 test classes (and two samples run by them), 126 tests |

Out of the first image, as kernel.md decided: ScaledDecimal, Date and Time,
Random, regular expressions, Unicode normalization and graphemes, text
formatting, Bag, SortedCollection, LinkedList.

**Well-known classes.** The VM's 27 well-known classes keep their indices,
formats and metaclasses; their kernel files must agree with the VM's
format (named slots and kind; the build refuses otherwise) and declare no
class-side instance variables, and the build gives them the superclass the
file names (SmallInteger under Integer, String under ArrayedCollection,
Float under Number, True and False under Boolean, WeakArray under
ArrayedCollection). Every other class gets two new indices, from 55.

**String** as kernel.md decided: no `size` and no `at:` (both answer an
error that says what to use), no `at:put:` (the primitive refuses it too);
`do:`, `reverseDo:`, `collect:` (a String: the block answers Characters),
`select:`, `detect:`, `includes:`, `asArray` over scalars; positions are
byte offsets (`indexOf:`, `indexOfSubstring:`, `copyFrom:to:`,
`keysAndValuesDo:`, stream positions), a position inside a scalar is an
error; `utf8` a read-only constant-time byte view (`Utf8View`);
`scalarCount`; `,`, `asUppercase`, `asLowercase` (ASCII), `trimmed`,
`beginsWith:`, `endsWith:`, `includesSubstring:`, `replaceAll:with:` (a
new String), `splitOn:`, `lines`, `substrings`, `asSymbol`, `asInteger`,
`asNumber`, `asFloat`, `printString`, `displayString`; `=` and `hash` over
the bytes (canonical equivalence waits for normalization; the class comment
says so), comparison by scalar value. A Symbol is never `=` to a String.

Where the index-free protocol made kernel code awkward (evidence for the
owner):

- Every inherited Collection method written on `size` or `at:` had to be
  overridden for String (`first`, `last`, `first:`, `allButFirst`,
  `reversed`, `asArray`, `collect:`, `select:`, `isEmpty`); the ones written
  on `do:` (`detect:`, `includes:`, `inject:into:`, `count:`) worked as they
  were. Writing collection code on `do:` first is the lesson.
- `last` and `reverseDo:` need a backwards boundary search
  (`previousBoundary:`), a loop over `isBoundary:`.
- `copyFrom:to:` with an inclusive byte end is easy to get wrong for a
  multi-byte last scalar (`'añ' copyFrom: 1 to: 2` is an error; the test
  says so).
- Number printing builds digits through a String WriteStream and reverses
  them (no `at:put:` into a buffer of known size).
- The Smalltalk compiler's scanner works in byte offsets throughout, which
  turned out natural: tokens are byte ranges, and only identifiers need
  `scalarAt:`. Nothing in the compiler wanted a scalar index.
- `String new: n` is refused (it would be n NULs); `String new: n withAll:`
  and `String new` (empty) remain.

**Exceptions** (ANSI over ADR 0009 section 5): `signal` remembers its own
Context and walks handler-marked frames from its sender
(`findNextHandlerContextStarting`); a handler frame's first two temps are
the exception class (or ExceptionSet) and the handler block, the third its
busy flag, set while the handler runs so a signal inside a handler goes
outward. The handler block runs on top of the signaling stack: falling off
its end or `return:` answers from `on:do:` (through `Context>>return:`,
which unwinds), `resume:` answers from `signal` (or from `outer`), `retry`
returns a marker to a loop in `on:do:` that runs the protected block again
(`on:do:` is a plain method looping over `privateOn:do:`, which carries the
handler mark: there is no frame restart primitive), `pass` searches from
the handler's sender, `outer` likewise but a resumption answers from
`outer`. Unhandled: Error signals UnhandledError, whose default action
writes the exception and its frames on the Transcript and terminates the
Process; Warning writes and answers nil; Notification answers nil.
`ensure:` and `ifCurtailed:` carry the unwind mark with the block as temp 1
and the complete flag as temp 2, the layout `Context>>resume:through:`
reads (Smalltalk-80's protocol, as 8a's kasm test kernel had it). The VM's
three sends land here: `modificationForbiddenAt:value:` (Object, signals
ModificationForbidden, resumable), `cannotReturn:` (BlockClosure, signals
BlockCannotReturn), `aboutToReturn:through:` (Context).

**Processes.** `[...] fork`, `forkAt:` over primitive 20; ProcessorScheduler
is the scheduler's protocol on the class side (`activeProcess`, `yield`,
`workerId`); Semaphore (`critical:`), a reentrant Mutex, Monitor (wait and
signal inside `critical:`), SharedQueue, Delay (primitive 25). They run in
parallel on the VM's workers; the kernel's collections are not synchronized
(ADR 0009 section 12): ProcessTest shares an OrderedCollection only through
a SharedQueue and a counter only through a Mutex.

**Weak and ephemerons.** WeakArray is the VM's weak format; an Ephemeron
(`key:value:finalizer:`) is kept in a registry until mourned; the
finalization Process (primitives 36 and 37) starts with the first such
ephemeron in each run (images hold no Process in 8b) and runs the
finalizer with the value. WeakTest: a WeakArray slot is nil after a
collection, a dropped key's finalizer runs, a held key stays.

**Pragmas and their index.** `CompiledMethod>>pragmas`, `pragmaAt:`,
`Pragma allNamed:` (from the index, a dictionary lookup), `allNamed:in:`
(one class). The index (`PragmaIndex`) is built by the kernel's
initialization at build time, kept by `Behavior>>addSelector:withMethod:`
and `removeSelector:`, and saved with the image, so a loaded image has it
without the loader rebuilding it (a deviation in mechanism, below). The
uses in 8b: `<primitive:>`, the test tags `<slow>`, `<device>`,
`<expectedFailure>` (declared by TestCase), and `<mainThread>` and
`<devProtocol>` (declared by Pragma; nothing reads them yet).

**Smalltalk** (class side) is the system: `allClasses`, `allBehaviors`
(the class table through primitives 118 and 119), `at:`, `classNamed:` (a
table by name), `instanceVariableNamesOf:` and `categoryOf:` (from the
synthesized `kernelDefinitions`: name, superclass, instance variables,
class-side instance variables, category and kind of every class, so the
compiler in Smalltalk knows instance variable names, which class objects do
not hold), `sourceOf:` (every method's source, recorded by the build),
`initializeKernel` (each class's own class-side `initialize`, superclasses
first, then the pragma index), and the entry points.

## The compiler in Smalltalk

`Scanner`, `Parser` and the parse nodes, `TempVariable` and `CompilerScope`
(the analysis), `Compiler` (code generation) and `BytecodeGenerator` (the
opcode table, the literal frame, the `ext` prefix, jumps, and the
verifier's stack-depth trace for `maxStack`), producing `CompiledCode`
(bytecodes, literals with block methods as CompiledCode and pragmas as
PragmaLiteral, the header). `CompiledCode>>matches:` compares it with an
installed CompiledMethod: bytecodes, every literal (floats by their
shortest spelling, which tells -0.0 from 0.0; arrays element by element;
block methods recursively; pragmas by selector and arguments), argument and
temp counts, `maxStack`, primitive, flags, copied values.

`CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid` compiles every
method of every class and metaclass in the image from its recorded source
and compares it with the installed method, which the bootstrap compiled:
**all 1368 match**; `knownDifferences` (the list of explained differences
the brief asks for) is empty. With the Smalltalk compiler broken by hand to
push 127 as a literal rather than with `push_int`, the test fails naming
the one method that has a 127 (`Character>>isLetter`) and both byte
sequences. The test takes 11 s in a debug build (the comparison compiles
the whole image in Smalltalk on the interpreter); it is tagged `<slow>`.

The Smalltalk compiler's output is not installed: the VM has no primitive
that makes a CompiledMethod from Smalltalk (Not done).

## The image build

`kajo build-image [-o kernel.img] [--no-init] [dirs or files...]` (default
`kernel/`), also `KernelBuild.build` (Swift):

1. read every `.st` file (Tonel), order the classes superclasses first,
   compute layouts (inherited instance variables first) and formats;
2. define the classes in a fresh image (`Image.defineKernelClasses`: the
   well-known ones checked and re-parented, the rest made);
3. compile every method (and the synthesized `kernelDefinitions`), warn on
   unconsumed pragmas, install (`Image.installKernelMethods`: the kasm
   loader's instance-variable, sealing, duplicate and size rules);
4. name the entry point (special object 7: the class Smalltalk);
5. run `Smalltalk initializeKernel` in a Process on a one-worker VM, then
   hand over every method's source (`Smalltalk recordSources:`, Arrays of at
   most 2000 Strings made by the host);
6. save: module 8a's image format, collected first; the loader verifies it
   all or nothing.

Any compile, define or install error refuses the whole build. The kernel
builds in 0.55 s (debug; 56 ms in release) to a 2.5 MB image. Compiling and installing
is deterministic to the byte; the initialization runs in a VM, where which
worker allocates decides entry placement and so identity hashes, and two
builds differ in a few bytes (4 of 900 000 in one comparison) at the same
length.

The first build after sources were recorded was 20 MB: `Smalltalk at:`
rebuilt the list of all classes for each of 1368 sources, and the garbage
left the entry table's high-water mark near 1.25 million entries, which the
snapshot writes (16 bytes each) even after a collection. `at:` now goes
through a class table by name. A snapshot's size follows the peak number of
entries, not the live ones: a build step that makes much garbage should
run with a nursery or collect, a fact for 8c's image saving.

**The entry point.** Special object 7 names the object `kajo run` and
`kajo test` start at (nil in a kasm image). `kajo run image.img --workers
n` sends it `setup: n` once and `run: i of: n` in one fresh Process per
worker, as kasm runs send them to nil (the kernel's Smalltalk forwards both
to nil when UndefinedObject understands them: the benchmark kernels are
extensions of UndefinedObject); `kajo test` sends it `test: arguments`. An
image that later carries saved Processes (8c) keeps this slot for the
fresh start and adds its Processes beside it; nothing in 8b refuses or
assumes more than 8a's loader does (it still refuses a Process and a live
Context).

## The test harness and the event stream

`kajo test [image] [--filter pattern] [--tag tag] [--junit path]` (built
from `kernel/` when no image is given). The kernel's TestRunner collects
every concrete TestCase's `test*` selectors (sorted; abstract classes'
inherited by their concrete subclasses), filters them (a pattern with `*`
matches the whole `Class>>selector`, without it any part), selects by tag
(a method pragma), and runs each in a fresh instance between `setUp` and
`tearDown`. TestFailure is an Exception, not an Error, so `on: Error do:`
in code under test does not swallow an assertion. An `<expectedFailure>`
test passes when it fails and fails when it passes.

The CLI's stdout is the NDJSON event stream: one JSON object per line,
written as each event happens, every object `{"v":1,"kind":...,"ts":...,
"process":...}` with `ts` in microseconds since 1970 taken when the event
happened (in the primitive, not when written) and `process` the emitting
Process's id. Kinds:

| kind | fields |
|---|---|
| `run.started` | `total`, `filter`, `tag` |
| `test.started` | `test` (`Class>>selector`), `class`, `selector`, `tags` |
| `test.passed` | the same, `us` (duration), `expectedFailure` when it was one |
| `test.failed`, `test.errored` | the same, `us`, `message`, `exception` (class name), `frames` (`Class>>selector` from the signaler down, the exception's own frames skipped) |
| `transcript` | `text`: one line of Transcript output |
| `gc` | `collection` (scavenge, full, finalMark, apply, initialMark, verify), `pauseUs`, `ttspUs`, `slowestWorker`; one `summary` with the pause and collection counts |
| `run.finished` | `total`, `passed`, `failed`, `errored`, `us` |

The kernel emits events through primitive 140 (`emitEvent: kind fields:
anArray`, alternating keys and values: Strings, Symbols, SmallIntegers,
Floats, Characters, nil, Booleans and Arrays of them), which builds the JSON
in Swift (escaping is the VM's, not the kernel's) and hands it to the host
hook `VMHooks.event`; nothing in it is test-specific. The `gc` events come
from the stop log after the run, each stamped with when its pause began
(`StopRecord.atNs`, new). The summary on stderr and the JUnit XML (`--junit`:
a testsuite per class, failure and error elements with the message, the
exception class and the frames, the Transcript as system-out) are derived
from the events at the end (`TestReport`), so there is one source of truth.
The exit status is 0 when every test passed, 1 otherwise, 2 when the run
itself failed. `kajo test` waits for the entry Process alone
(`VM.waitUntilTerminated`, new), then terminates any other (the
finalization Process waits forever).

`kajo run` prints the Transcript on stderr (each `transcript` event's
text).

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS 27,
swift.org Swift 6.4.2, 2026-11-03 20:23 to 20:28 (load average 3.3 to 4.0
1-minute, the agent session the busiest other process). The starting
commit's `kajo` (d5179ce, from a worktree) against this module's, both
built `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
`--slice-ms 0`; median (min to max) ms. The checksums are the published
ones and equal on both sides.

### The kasm kernels against the starting commit

| kernel | workers | d5179ce ms | 8b ms | 8b / start | checksum |
|---|--:|--:|--:|--:|---|
| fib | 1 | 1705.8 (1693 to 1712) | 1702.3 (1693 to 1708) | **0.998** | 24682992 |
| fib | 8 | 226.8 (218 to 230) | 223.0 (217 to 250) | **0.983** | 24682992 |
| arith | 1 | 2558.2 (2546 to 2564) | 2552.4 (2543 to 2575) | **0.998** | 372800000 |
| arith | 8 | 347.9 (341 to 355) | 349.4 (336 to 374) | **1.004** | 372800000 |
| sends | 1 | 2578.7 (2571 to 2629) | 2573.3 (2560 to 2610) | **0.998** | 1066666666666668 |
| sends | 8 | 341.2 (335 to 394) | 337.0 (329 to 390) | **0.988** | 133333335000001 |
| ivars | 1 | 1981.4 (1974 to 2018) | 1975.5 (1968 to 2015) | **0.997** | 36383626 |
| ivars | 8 | 279.5 (255 to 304) | 261.8 (254 to 290) | **0.937** | 71714128 |
| storeheavy | 1 | 2422.0 (2414 to 2425) | 2419.3 (2404 to 2462) | **0.999** | 512000 |
| storeheavy | 8 | 312.2 (308 to 323) | 332.3 (311 to 335) | **1.064** | 512000 |
| alloc | 1 | 2973.4 (2928 to 3024) | 2971.4 (2965 to 3092) | **0.999** | 41950911 |
| alloc | 8 | 484.5 (435 to 514) | 467.1 (457 to 585) | **0.964** | 42008248 |

Within noise: 0.997 to 0.999 on one worker; on eight 0.94 to 1.06, where
the runs' ranges overlap (storeheavy 1.064: 308 to 323 against 311 to 335;
ivars 0.937). `interpret` is the same code: its disassembly in both aligned
builds is identical instruction for instruction (1326 lines, 217 stack
loads), 1056 instructions in `just arc-check`'s build, one jump table.

**A first A/B with plain aligned builds** (`-c release` with the two
alignment flags, no `-enable-testing`; 20:15 to 20:20) was not: the 8b
binary ran every kernel 12 to 36 percent slower (fib 1.158, arith 1.232,
ivars 1.316 on one worker). Its `interpret` is the same code as the
starting commit's too, and the plain release builds without the alignment
flags run fib at 1696 and 1703 ms (start, 8b), as do the `-enable-testing`
aligned ones (above). So it is where that one link put the hot code, not
the code; reported here because AGENTS.md says not to read one layout as a
verdict, and because a future A/B may land on it again:

| kernel | workers | d5179ce ms | 8b ms | 8b / start | checksum |
|---|--:|--:|--:|--:|---|
| fib | 1 | 1700.8 (1690 to 1702) | 1970.3 (1967 to 1977) | **1.158** | 24682992 |
| fib | 8 | 225.3 (217 to 240) | 260.4 (253 to 270) | **1.156** | 24682992 |
| arith | 1 | 2543.3 (2529 to 2547) | 3133.2 (3130 to 3141) | **1.232** | 372800000 |
| arith | 8 | 337.6 (336 to 350) | 426.8 (414 to 436) | **1.264** | 372800000 |
| sends | 1 | 2584.8 (2570 to 2637) | 2934.6 (2924 to 2942) | **1.135** | 1066666666666668 |
| sends | 8 | 348.9 (338 to 372) | 389.3 (377 to 400) | **1.116** | 133333335000001 |
| ivars | 1 | 1970.5 (1968 to 1974) | 2593.1 (2592 to 2599) | **1.316** | 36383626 |
| ivars | 8 | 256.5 (252 to 270) | 348.2 (332 to 356) | **1.358** | 71714128 |
| storeheavy | 1 | 2401.9 (2394 to 2418) | 3095.4 (3092 to 3107) | **1.289** | 512000 |
| storeheavy | 8 | 331.4 (308 to 339) | 406.6 (398 to 429) | **1.227** | 512000 |
| alloc | 1 | 2947.2 (2937 to 2951) | 3305.2 (3289 to 3320) | **1.121** | 41950911 |
| alloc | 8 | 470.9 (440 to 502) | 530.1 (470 to 538) | **1.126** | 42008248 |

### Kernels written in Smalltalk against their kasm twins

The same algorithm compiled by the bootstrap compiler from Tonel
(`Fixtures/smalltalk/`), run from an image built with the kernel
(`kajo run <image>`: the entry point forwards `run:of:` to nil), against
the kasm kernel, both on the 8b binary, same session:

| kernel | workers | kasm ms | Smalltalk ms | Smalltalk / kasm | checksums |
|---|--:|--:|--:|--:|---|
| sends | 1 | 2587.5 (2549 to 2600) | 2285.6 (2257 to 2323) | **0.883** | 1066666666666668 / 1066666666666668 |
| sends | 8 | 335.4 (330 to 350) | 311.8 (289 to 322) | **0.930** | 133333335000001 / 133333335000001 |
| ivars | 1 | 1980.7 (1969 to 1982) | 1977.0 (1970 to 2163) | **0.998** | 36383626 / 36383626 |
| ivars | 8 | 264.5 (253 to 300) | 266.5 (252 to 289) | **1.008** | 71714128 / 71714128 |
| closures | 1 | 3748.5 (3742 to 3814) | 3847.0 (3819 to 3929) | **1.026** | 210210000 / 210210000 |
| closures | 8 | 499.3 (487 to 514) | 498.2 (495 to 518) | **0.998** | 209214000 / 209214000 |

- `sends` is 12 percent faster in Smalltalk: the kasm kernel sends `at:`
  and `\\` as full sends (`send at: 1`), the compiler uses the special
  `at` and `mod` opcodes, whose fast paths answer an Array's `at:` inline.
- `ivars` is the same code (the store and load bytecodes the compiler emits
  are the kasm kernel's, with the loop counter in a temp instead of the
  argument).
- `closures` is 2.6 percent slower on one worker: the block answers its
  assignment (`dup`, `store_tv_slot`) where the kasm block pushed nil, and
  `\\` goes through the special send's tier.

### The image build and the tests

The kernel builds in 0.55 s in a debug build and 56 ms in release (123
classes, 1368 methods, 2.5 MB image); `kajo test` runs the 126 kernel tests
in 11.6 s in a debug build, 11 of which are CompilerTest's whole-image
comparison.

## Changes to module 8a

The owner's answers (2026-11-03), built here:

- **`modificationForbiddenAt:value:`.** A refused store sends the
  two-argument selector to the object (index, value): `Frames.swift`'s
  `modificationForbiddenFromStore` and `...FromPrimitive` (renamed from
  `attemptToModifyFrom...`) build [object index value] and send with argc
  2; `VMSelector.modificationForbidden`; the store opcodes' transient depth
  is 2 (was 3), so `maxStack` of a method that stores an instance variable
  is one lower; the read-only kasm test kernel and `ImageTests`' expected
  `maxStack` follow. The kernel's Object implements it by signaling
  ModificationForbidden.
- **The weak symbol table.** WeakArray is well-known class 27 (weak
  variable; the metaclasses are 28 to 54, user classes from 55); the
  symbol table's buckets are WeakArrays, so the collectors (module 1's
  mark, the scavenge, the concurrent marker's final mark) nil a Symbol
  nothing else references. The nil is a tombstone: a lookup scans its
  whole bucket (a hole is no longer the end) and an insertion takes the
  first nil. A Symbol found by a lookup (`Machine.intern`, primitives 129
  and 135) goes through module 5's weak read barrier, so one found while a
  cycle marks is kept alive. The image verifier accepts holes and requires
  WeakArray buckets. The host-side loader now roots each Symbol it interns
  until something holds it: with the table weak,
  `loadingSurvivesACollectionAtEveryAllocation` failed because a selector
  interned before its method was made was collected at the next
  allocation; the boot's special selectors and `doesNotUnderstand:` too.
  The barrier site `symbolTable` is unchanged (`aBarrierSiteSwitchedOff`
  passes).

Module 1 (found by this module's gate run of `just fuzz snapshot 600`,
40 s into it; the input crashes the starting commit too): the snapshot
loader refuses a snapshot whose nil object is not one of its roots. The
image boot registers nil as a root and every snapshot taken from an image
has it, but the loader never checked: a one-bit mutation of the seed named
a nil object no root held, the collection `FuzzEntry.snapshot` runs after
loading swept it, and the verifier trapped ("object memory verifier, after
sweep: the nil object (a root) is @3"). The input is a regression fixture
(`crash-nil-not-root.img`, `fuzzFoundInputsNeverTrap`).

What the kernel needed:

- Primitives (`ObjectModel/KernelPrimitives.swift`): 75 Float
  `printString` (Swift's shortest round-trip digits in Smalltalk's
  spelling), 78 String `asFloat` (Swift's `Double(_:)`, the bootstrap
  compiler's reader, so both compilers read float literals alike), 117
  `slotAt:` (a pointer slot of any object, sealed ones included: reading
  cannot undo what sealing protects, since bytecodes, literal Arrays and
  Symbols are read-only and the class objects and method dictionaries stay
  unwritable; AGENTS.md's "no primitive reads" for Class, Method and
  MethodDict is relaxed to reads), 118 `classAt:`, 119 `classCount`, 140
  `emitEvent:fields:` and the `event` hook, 141 a monotonic microsecond
  clock. Counter `events`.
- The assembler takes a structured input (`AsmMethod`, `AsmLine`); kasm
  lowers to it (`lower`), with the same checks and messages.
- `Literal` gains `.array` and `.byteArray` (literal arrays, read-only,
  pinned like other literals).
- `package` access for what KajoCompiler uses (Opcode and its tables,
  Literal, AssembledMethod, AsmMethod, LoadError, LoaderLimits,
  `isSelector`, `isIdentifier`, `arity`, Image's kernel-build methods).
  `interpret` is unchanged (1056 instructions, one jump table).
- `Image`: `defineKernelClasses`, `installKernelMethods`, `setEntryPoint`,
  `entryPoint` (special object 7), `bootForKernel`, `runToCompletion`
  (a class-side method in a one-worker VM, with an optional Array of
  Strings).
- `Headless`: `run(image:)` (a saved image's entry point, the kasm
  protocol), `test(image:arguments:events:)`, `Options.events`,
  `isImage`; `configs` factored out of `run`.
- `VM`: `waitUntilTerminated(_:)` (the host waits for one Process: the
  scheduler state names a watched id and its termination broadcasts the
  done condition), `newStringArray`.
- `StopRecord.atNs`.

## Deviations

From kernel.md and ADR 0009, each with its reason:

- **No class variables** (`#classVars` is refused). Shared state is
  class-side instance variables (Transcript, Ephemeron, Smalltalk,
  PragmaIndex), which need no bindings in literal frames; class variables
  would need Association literals that are not read-only, and a rule for
  them in both compilers. Left for when a class needs one.
- **No globals but classes**: `Processor` is ProcessorScheduler's class
  side, `Transcript` a class with a class-side stream, `Smalltalk` a class.
- **The pragma index is saved in the image**, built by the kernel's
  initialization and kept by installation; the image loader does not
  rebuild it (it would have to run Smalltalk, and the saved one is
  current).
- **Unconsumed pragmas warn on stderr** at build time, not as an event:
  the v1 event kinds have none for compile warnings.
- **`<mainThread>` and `<devProtocol>` are declared, not acted on**: the
  scheduler's check in checked builds and the remote UI are not built.
- **The unwind and handler marks are pragmas** (`<unwind>`, `<handler>`)
  that the compilers consume, as `<primitive:>`.
- **`retry` loops in `on:do:`** over `privateOn:do:` (the handler frame);
  there is no frame-restart primitive.
- **`Process>>terminate` does not run ensure blocks** (the VM's terminate
  cuts the stack).
- **Inlined loop bodies' captured and assigned temps are shared across
  iterations** (one temp vector for the enclosing real scope); the loop
  counter itself is per iteration (above).
- **`gc` events are emitted after the run**, each stamped with its pause's
  start: the stop log is read once the Processes have ended.
- **Objects are at most one block** (module 1): an Array or
  OrderedCollection holds at most 4095 elements and a String 32 760 bytes.
- **Float has no transcendental functions** (only the 8a primitives:
  arithmetic, `sqrt`, `truncated`, `exponent`, `timesTwoPower:`).
- **Character classification and case are ASCII**; above 127 every
  non-separator counts as a letter, and the Smalltalk scanner takes such
  scalars in identifiers where Swift's takes Unicode letters (the kernel's
  identifiers are ASCII).
- **String `collect:` answers a String** (Pharo's), so its block answers
  Characters.

## Tests

Swift: 300 `KajoVMTests` (module 8a: 297; the 3 new `WeakSymbolTests`)
and 20 `KajoCompilerTests` (new):

| file | tests |
|---|---|
| CompilerTests | the instructions of a method, **captured and assigned variables in a temp vector**, captured and unassigned ones copied, inlined control flow without closures, non-local return marks its blocks, literal and brace arrays, pragmas, 20 malformed sources refused, compiled methods run (loops, closures, non-local return, nil tests, class-side state, cascades, nested blocks, logic), **1500 seeded mutations of kernel files compile or are refused**, **a compilation frees its scopes and variables** |
| KernelImageTests | **the kernel builds without warnings and loads**, **its tests pass headless and the events are the v1 protocol in time order**, filter and tag select, **a failure carries its message and frames into the events, the summary and JUnit**, the Transcript is an event with its Process, **load and save round trip to the same bytes and the reloaded image's tests pass**, the build is deterministic before initialization, broken class files refuse the build, an unconsumed pragma warns |
| WeakSymbolTests | **an unreferenced Symbol is collected, its slot is reused by the next interning of the same bytes, one Symbol per spelling**, a referenced Symbol survives, the table survives image round trips with tombstones |

Smalltalk (`kajo test`, and through `theKernelsTestsPassAndTheEventsAreTheProtocol`):
126 tests in ObjectTest, BooleanTest, IntegerTest, FractionTest,
FloatTest, CharacterTest, StringTest, SymbolTest, ArrayTest,
OrderedCollectionTest, IntervalTest, SetTest, DictionaryTest, StreamTest,
ExceptionTest (return, resume, handler selection, exception sets,
`ensure:`, `ifCurtailed:`, non-local return through ensure blocks, retry,
pass, outer, signals inside handlers, frames), BlockClosureTest,
ProcessTest (fork, a SharedQueue between ten Processes, a Mutex around a
counter shared by four, Monitor, Delay, terminate), WeakTest,
ReflectionTest, PragmaTest, ReadOnlyTest (a refused store signals
ModificationForbidden with the object, index and value; method literals
are read-only), SUnitTest, TranscriptTest, CompilerTest.

## Broken variants run by hand

| rule | broken variant | test | result |
|---|---|---|---|
| the two compilers agree | the Smalltalk compiler's `push_int` range to 126 | `CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid` | fails: "1 differ, the first: Character>>isLetter: bytecodes #[... 36 1 2 22 ...] against #[... 36 11 127 22 ...]" |
| an inlined argument is copied | the loop's increment counted as an assignment (the first version) | `ProcessTest>>testManyProcessesWithASharedQueue` | fails: the forked blocks shared the counter's temp vector and read a later value |
| the loader roots the Symbols it interns | no root between interning a selector and storing it (the first weak-table version) | `loadingSurvivesACollectionAtEveryAllocation` | fails: `img.lookup(Leaf, step:)` finds nothing (the selector was collected) |
| a compilation leaks nothing | `Variable.scope` a strong reference (the first version: a cycle with the scope's variable lists) | `aCompilationFreesItsScopes`; `just fuzz syntax 600` | the test fails (the method scope, a variable and a block scope outlive the tree); the first 600 s libFuzzer run of the syntax target stopped after 4.5 minutes with "libFuzzer: out-of-memory (used: 2049Mb; limit: 2048Mb)", allocations in `Compiler.declare` and `Scope.init` |
| the snapshot loader refuses a nil that is not a root | the check removed (the starting commit's loader) | `fuzzFoundInputsNeverTrap(crash-nil-not-root)`, replayed through the fuzz entry | on the starting commit the replay traps: "object memory verifier, after sweep: the nil object (a root) is @3" |
| nested results emit no events | every TestResult emitting (the first version) | `kajo test` | SUnitSample's deliberate failures appeared as `test.failed` events and in the summary, while `run.finished` counted none |

The `ios-check` recipe gained `-package-name kajo`: KajoVM's `package`
declarations need a package name on the bare `swiftc` command line (the
gate's first run on this module failed with "the package access level used
on 'Opcode' requires a package name").

## Unsafe surface

`KajoCompiler` has no `unsafe` (it builds with strict memory safety and
uses only safe code); `fuzz-syntax` has the one line every fuzz target has.
In `KajoVM` (lines with `unsafe`, comments excluded): `KernelPrimitives.swift`
6 new (the worker pointer, the Process id, the event hook call),
`Headless.swift` 11 to 22 (the event hook and its context), `VM.swift` 152
to 166 (`waitUntilTerminated`), `Strings.swift` 9 to 11 (the weak read
barrier on lookups), `Scheduling.swift` 185 to 187 (the watched Process),
`Frames.swift` 166 to 164. The whole `Sources/KajoVM` has 4266 such lines
(4233 at the start). Counted on the final commit's clean build (0
warnings).

## Hot-path check

`just arc-check` on the final code: 135 functions, zero
`swift_retain`/`swift_release`; `interpret` 1056 instructions (module 8a:
1056), one indirect branch, one jump table. 8b put nothing new on the
interpreter's paths: the new primitives (`kernelPrimitive`, which builds
an event's JSON in Swift arrays) are out of line behind the primitive
table's one call and not on the list; `Machine.intern` and
`stringPrimitive`, which are, gained the weak read barrier's call and stay
free of ARC. The aligned builds' `interpret` is the same code as the
starting commit's, instruction for instruction (Measurements).

## Not done

- Saved Processes in images: module 8c, next (the entry point stays
  beside them).
- A primitive that makes a CompiledMethod from the Smalltalk compiler's
  output and installs it (the compiler compiles and compares; it does not
  install, so there is no `Compiler evaluate:` yet).
- Class variables; non-class globals.
- Unicode tables (classification, case mapping beyond ASCII,
  normalization, graphemes); transcendental floats.
- The scheduler's main-thread check for `<mainThread>`; the development
  protocol.
- `Process>>terminate` running unwind blocks; a frame restart.
- A per-iteration temp vector for captured temps of inlined loop bodies.
- Compile warnings as events.
- Out of the first image by decision: ScaledDecimal, Date and Time (a
  Temporal-style API later), Random, regular expressions, Bag,
  SortedCollection, LinkedList.

## Open questions for the owner

Each has a provisional answer the build took. The owner answered on
2026-11-04 (recorded after each question); 1, 2 and 4 change the build
and are module 8d's brief, `docs/modules/kernel-live.md`.

1. Should captured, assigned temps inside inlined loop bodies get a fresh
   temp vector per iteration (Pharo's rule), at the cost of a per-iteration
   rule in both compilers? Provisional: one vector per real scope, shared
   across iterations (the loop counter itself is per iteration).
   **Owner: do it like Pharo** (a fresh temp vector per iteration; module 8d).
2. Are class variables wanted, or are class-side instance variables
   enough? Provisional: none; `#classVars` is refused.
   **Owner: add class variables** (module 8d).
3. Should compile warnings become an event kind in the protocol?
   Provisional: stderr at build time. **Owner: agreed.**
4. Is a primitive that makes a CompiledMethod from the Smalltalk
   compiler's output and installs it acceptable? It would re-verify the
   method and pin it, and it is what `Compiler evaluate:` needs.
   Provisional: not built; the compiler compiles and compares only.
   **Owner: allow installing from Smalltalk, with some flag that can
   forbid it on "release images" (the flag's form to be decided)**
   (module 8d).
5. May the image build stay byte-deterministic only before the kernel's
   initialization? Initialization runs in a VM and worker placement moves
   a few bytes (4 of about 900 000 in one comparison). Provisional: yes;
   a test checks the build is deterministic before initialization and the
   final image by its verifier and a load-save round trip.
   **Owner: agreed.**

## Gates

On the final code commit (`f92dd1b`; the commit after it adds only this
table), the whole sequence once more, on the Mac mini (M2 Pro) with the
swift.org 6.4.2 toolchain, every output in a file:

| gate | result |
|---|---|
| `swift test` | 300 + 20 passed, 95 + 16 s |
| under load (12 busy loops) | 300 + 20 passed, 124 + 19 s |
| ThreadSanitizer | 300 + 20 passed, 0 reports, 377 + 402 s |
| ThreadSanitizer under load | 300 + 20 passed, 0 reports, 557 + 465 s |
| `just ios-check` | 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release, `interpret` 1056 instructions, one jump table |
| `just golden` | 12 of 12 checksums (9 kasm, 3 Smalltalk) |
| `just test-release` | 300 + 20 passed |
| `just model-check` | 28 + 15 passed |
| `just soak` | passed |
| `just fuzz kasm 600` | libFuzzer, 2.56 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer, 7.72 million runs, no crash |
| `just fuzz syntax 600` | libFuzzer, 1.90 million runs, no crash |
| clean build | 0 warnings |

(300 is `KajoVMTests`, 20 `KajoCompilerTests`, whose kernel-image suite
runs the kernel's 126 SUnit tests.) Two earlier full runs each found
something the gates exist for: on `2704529`, `ios-check` failed (the
recipe lacked `-package-name`) and the syntax fuzzer ran out of memory
(the compiler's reference cycle), both fixed in `62fa9d1`; on `62fa9d1`,
the snapshot fuzzer crashed after 40 s (the nil-object root, a module 1
bug as old as the starting commit), fixed in `f92dd1b`.

## Commands

```zsh
just build-image                 # kernel/ -> kernel.img
just kernel-test                 # build kernel/ and run its tests (NDJSON on stdout)
swift run kajo test kernel.img --filter StringTest --junit junit.xml
swift run kajo run kernel.img    # the entry point's run:of:
kajo build-image -o sends.img kernel Tests/KajoVMTests/Fixtures/smalltalk/sends
kajo run sends.img --workers 8 --slice-ms 0
just fuzz syntax 600
```
