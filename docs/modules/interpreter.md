# Module 2: interpreter and loader

Status: built, 2026-11-02. `Sources/KajoVM/Interpreter/` and
`Sources/KajoVM/Loader/`, tests in `Tests/KajoVMTests/Interpreter/` and
`Tests/KajoVMTests/Loader/`, fixtures in `Tests/KajoVMTests/Fixtures/`.
Ported from experiments/vm-language-bench (bytecodes, frames, cache, kasm),
object-representation (variant B) and concurrent-young (the `result`
register rule), by their tests first.

## What it hides

How a method runs: the bytecode encoding, the frame layout on a stack, how
a send finds a method, how a primitive is entered and fails. Nothing
outside this module reads a bytecode or a frame word. The object memory
stays the only module that computes a body address: the interpreter reaches
slots through `load`/`store` and holds exactly two raw body pointers, the
running method's bytecodes and literal frame, which it gets from module 1's
`bytesBase`/`slotsBase` and re-derives after every call that can pause.

## What is and is not decided

**Bytecode set v0** is the experiments' set, carried in as the encoding the
first loader reads, not as Kajo's bytecode set. No blocks, non-local return,
super sends, metaclasses, LargeInteger, Float or String. Those wait for the
bytecode-and-object-model ADR before module 8.

What an ADR changes:

- **Numbering and operand formats**: `Interpreter/Opcodes.swift` only. The
  `Opcode` enum (raw values contiguous from 0 in declaration order) holds the
  mnemonics, operand formats, lengths, stack effects and special selectors;
  `OperandDecoding` decodes operands. The assembler, the stack-depth
  verifier and the dispatch loop read all of it from there.
- **Adding or removing an opcode**: the enum, plus one `case` in
  `Interpreter/Dispatch.swift`. Frames, sends, primitives and the lookup
  cache never see an opcode number.

## Layouts

### Stack and frame (`Interpreter/Stack.swift`)

A `Stack` is malloc'ed words, outside the heap, grows up. Word 0 is nil and
every word in `[0, sp]` is a valid oop, so it is scanned uniformly. The
interpreter takes a stack as an argument (module 3 gives one per Process).

```
fp[0]               receiver             pushed by the caller
fp[1 ... argc]      arguments            pushed by the caller
fp[1 + argc ...]    temps, nil
hdr[0]              method               hdr = fp + 1 + argc + temps
hdr[1]              caller pc            SmallInteger: offset in the caller's bytecodes
hdr[2]              caller fp            SmallInteger: word index; 0 = the host
hdr[3]              caller hdr           SmallInteger: word index
hdr[4 ...]          operand stack, at most the method's maxStack words
```

The links are offsets and indices, not addresses (a deviation from
SPEC-SHARED, see below): compaction moves bytecodes under live frames and
module 3 may move stacks, and nothing in a stack needs fixing for either.
Activation checks `sp + temps + 4 + maxStack + 1 < stackEnd` (the extra word
is for the Message a unary `doesNotUnderstand:` pushes); return writes the
result over the receiver and sets `sp = fp`.

### Registers

Live, in machine registers (`Regs`, `Interpreter/Send.swift`): `pc`, `sp`,
`fp`, `hdr` as pointers, and the two cached bases `code` and `lits`.
Saved, as the collector and the host see them (`SavedRegisters`,
`Interpreter/InterpreterState.swift`): `pc` (offset), `sp`, `fp`, `hdr`
(word indices), `receiver`, `method` and `result` (oops). Every slow path
that can pause writes the saved form first (`save`) and rebuilds the live
form after (`restore`, which re-derives `code` and `lits` from the method
oop). At a pause the roots are the stack words `[0, sp]` and every
oop-valued saved register.

The `result` register holds what the bottom frame returned until the host
takes it (`takeResult`), and is a root only while it holds a value:
concurrent-young found a stale result keeping dead objects alive and hiding
a lost one (its SPEC, amendment 8). `theResultRegisterIsARootOnlyWhileLive`
fails without the clearing.

### Interpreter state

`InterpreterState`, one 128-byte aligned allocation per interpreter (per
worker from module 3): the object memory, an allocation context, nil, true,
false, the globals Array, the `doesNotUnderstand:` selector, a pointer to
the special selectors, the lookup cache, the safepoint flag pointer, the
leave code, the attached stack's bounds, the saved registers, the exit
reason, the error record, a pause count and the counters. Plain values and
raw pointers only. Primitives and slow paths see it through `Machine`, a
safe wrapper with `allocate`, `collect`, `compact`, `become`, `fail` and the
well-known objects, so primitives handle oops and never an address.

### Object model v0 (`Interpreter/ObjectModel.swift`)

Well-known class indices 1 to 11 as SPEC-SHARED, plus 12 Message
(`selector`, `arguments`); user classes from 13. Class objects have 5 slots
(superclass, methodDict, name, instSize, classIndex; name is the class's
Symbol, the experiments left it nil). Methods have 7 (bytecodes ByteArray,
literals Array, argc, temps, maxStack, selector, primitive). A method
dictionary is a pointer object of 2 x capacity slots, capacity a power of
two at least max(8, 2 x count), key at 2i, hash `oop >> 4` (oops never
change, so the hash survives collections), linear probing.

**Structural classes.** Class, Method and MethodDict are the objects whose
shape the interpreter trusts (a Method's maxStack sizes the frame, its
bytecodes were verified by the loader). No primitive reads, writes, creates
or exchanges their instances (`at:`, `at:put:`, `basicNew`, `become:` fail
on them) and the loader refuses `push_ivar` and `store_ivar` in their
methods. Without that, `at:put:` on a method's bytecodes would undo the
verifier. A snapshot (module 1) is trusted for heap structure only; the
image format of module 8 must verify methods as the kasm loader does.

## Dispatch (`Interpreter/Dispatch.swift`)

`interpret(state, regs)`: fetch a byte, `switch Opcode.decode(byte)`, one
case per opcode. `decode` is one compare and an `unsafeBitCast` (the
synthesized `Opcode(rawValue:)` compiled to a call per bytecode and cost 49
percent on fib). Fast paths are inline. Everything else is one out-of-line
call taking the registers as scalars and answering the next registers. A
path that stops the loop answers registers whose pc is the leave code (a
byte, 0xFF, outside the set); the `nil` case returns on it, and otherwise
reports `invalidBytecode`.

`push_ivar` and `store_ivar` check the receiver's header (an object, not
bytes, slot below the count): the loader checked the index against the
class, but `become:` can change a running method's receiver.

## Send and the lookup cache (`Interpreter/Send.swift`)

`send` is `@_transparent` into the loop: poll; class index (SmallInteger
tag or one header load); probe the cache; on a hit `invoke`: the method's
primitive out of line, else an inline activation. A miss is one call
(`lookupMiss`) that walks the superclass chain's dictionaries
(`lookupMethod`, bounded by the class count) and fills the line.

- **Cache**: per interpreter (so per worker from module 3, rather than per
  stack), 1024 direct-mapped lines `{classIndex, selector, method}`, index
  `((selector >> 4) ^ classIndex) & 1023`. Flushed at every pause the
  interpreter takes part in (collection, compaction, become: its lines are
  oops) and when the image has loaded files since the last run (a load can
  shadow an inherited method).
- **Special sends** `+ - * < > <= >= =`: SmallInteger fast path on the
  tagged words, overflow detected with the `ReportingOverflow` operations;
  any other case is a real send of the selector (`specialSend`). `==` is
  inline.
- **doesNotUnderstand**: if the receiver's class understands
  `doesNotUnderstand:`, the arguments go into an Array, a Message replaces
  them on the stack and it is sent; else the error.
- **Safepoint poll** at every bytecode send and backward jump: one relaxed
  load of an `Atomic<UInt32>` the interpreter is given. Module 3 wires it to
  the safepoint protocol; here it is a test switch
  (`Interpreter.safepointRequested`) that makes each poll collect.

## Primitives (`Interpreter/Primitives.swift`)

A `switch` over the number (one jump table) to functions taking a `Machine`
and a `PrimitiveCall` (receiver, argc, up to two arguments, copied out of
the stack, where they stay as roots). Each answers its result or `.none`
for failure, after checking every type, bound and the argument count
itself.

| # | selector | checks |
|---|---|---|
| 1 | `at:` | argc 1; receiver an object, not structural; index a SmallInteger in 1...count; bytes answer SmallIntegers |
| 2 | `at:put:` | as `at:`; a byte value is a SmallInteger 0...255 |
| 3 | `basicNew:` / `new:` | argc 1; receiver a class object; not SmallInteger, not structural; size a SmallInteger >= 0, total at most a block (4095 slots, 32 760 bytes for ByteArray) |
| 4 | `basicNew` | as 3 with size 0 |
| 5 | `class` | argc 0 |
| 6, 7 | `//`, `\\` | argc 1; both SmallIntegers; divisor not 0; floor semantics; result in range |
| 8 | `become:` | argc 1; both objects, neither structural (module 1's two-way become) |
| 11 | `gc:` / collect | any argc: a stop-the-world collection with the interpreter's roots (test switch) |
| 12 | `compact:` / compact | any argc: a compaction (test switch) |
| 14, 15 | `globalAt:`, `globalAt:put:` | index a SmallInteger in 1...64 |
| 18 | `==` | argc 1 |
| 19 | `identityHash` | argc 0; the entry index (oops never change) |

Numbering follows the experiments; 18 and 19 are new. Any other number in
1...255 is accepted by the loader and always fails.

**Failure rule**: a primitive that fails runs its method's bytecodes as an
ordinary activation (the primitive may have a body; the experiments' kasm
never gave one); a method with no bytecodes stops with `primitiveFailed`.
An allocation that fails after collection and compaction is not a
primitive failure: it stops with `outOfMemory`.

Allocation in primitives and the send path goes through
`Machine.allocate`: `tryAllocate` inline, and on failure (or with the stress
flag `collectAtEveryAllocation`) one out-of-line `allocateSlow` that hands
module 1's `allocate` the interpreter's roots, flushes the cache and bumps
the pause count. The loop re-derives its bases after every primitive.

## Errors (`Interpreter/VMError.swift`)

Never an exit or a trap. The loop stops, the stack and saved registers stay
as they were (`Interpreter.backtrace` lists the frames), and `run` answers
`VMError(kind, selector, receiverClass, method, pc, primitive)`:

| kind | when |
|---|---|
| `doesNotUnderstand` | no method and no `doesNotUnderstand:` |
| `mustBeBoolean` | a conditional jump popped neither true nor false |
| `primitiveFailed` | a primitive failed and its method has no bytecodes |
| `stackOverflow` | the next frame does not fit the stack |
| `outOfMemory` | no room after a collection and a compaction |
| `invalidSlotAccess` | `push_ivar`/`store_ivar` outside the receiver (after a become:) |
| `invalidBytecode` | a byte outside the set (the loader never produces one) |

`pc` is the offset of the failing instruction in `method`.

## Loader (`Loader/`)

`parseKasm` (text to classes and methods, on bytes, with file and line in
every error), `assemble` (labels, literal frame in first-use order with
duplicates merged, encoding, then the **stack-depth verifier**: a dataflow
pass giving every reachable instruction one depth; underflow, two depths
meeting, falling off the end and depth over the limit are errors, so
`maxStack` is sound for any accepted input), and `Image` (boot, then
`load`). `Image.load` parses, assembles and checks everything before the
heap changes, so a rejected load leaves the image as it was; only
`heapFull` can stop a load part way. Every object it creates is reachable
from the class table or a root before the next allocation.

Every malformed input is a `LoadError(kind, message, file, line)`:
`syntax`, `badOperand`, `unknownOpcode`, `unknownLabel`, `duplicateLabel`,
`badStack`, `emptyMethod`, `methodTooLarge`, `tooManyLiterals`,
`unknownClass`, `duplicateClass`, `duplicateMethod`, `tooManyClasses`,
`tooManyMethods`, `badClass` (superclass cycle, fewer instance variables
than the superclass, an instance variable outside the class or in a
structural class), `heapFull`, `inputTooLarge`.

Limits (`LoaderLimits`):

| limit | value | why |
|---|---|---|
| source per file | 16 MiB | |
| class index | 65 536 | well below the 22-bit header field |
| methods per class | 512 | the dictionary is one object in one block |
| bytecodes per method | 32 760 bytes | one byte object in one block |
| literals per method | 256 | one-byte index |
| arguments + temps | 256 | one-byte index |
| operand stack per activation | 1024 | |
| instance size | 4095 | one block |
| `push_int` | -128...127 | |
| integer literal | SmallInteger range | |
| primitive number | 1...255 | |

Superclasses may be declared later in the same file; a method's class and
`@Class` literals must exist in an earlier file or the same one.

### Fuzzing

`FuzzEntry.kasm(bytes)` and `FuzzEntry.snapshot(bytes)` (module 1's
loader) are the entry points; after a load they run the heap and free-list
verifiers and trap on any report. `Sources/fuzz-kasm` and
`Sources/fuzz-snapshot` export them as `LLVMFuzzerTestOneInput`. Seeds are
in `Tests/KajoVMTests/Fixtures/fuzz/{kasm,snapshot}`.

`just fuzz <kasm|snapshot> <seconds>` (`scripts/fuzz.sh`) builds the target
with `-sanitize=fuzzer,address -DKAJO_LIBFUZZER`. The Xcode toolchain
cannot: `error: unsupported option '-sanitize=fuzzer' for target
'arm64-apple-macos15.0'` (it ships no `libclang_rt.fuzzer_osx.a`). The
swift.org toolchain does (swift-6.4.2-RELEASE, `TOOLCHAINS=swift`, the
script's default; `KAJO_FUZZ_TOOLCHAINS` overrides). Without one, the script
falls back to the same target built plainly, which replays the seeds and
mutates them without coverage guidance. Runs on 2026-11-02 with libFuzzer:
kasm 427 591 inputs in 61 s (1737 edges), snapshot 1 066 035 in 21 s (569
edges), no crash. The seeded-mutation tests stay as the in-suite stand-in:
`mutatedKasmLoadsCleanOrIsRejected` (3 000 mutations: byte flips, numbers,
deleted, duplicated and swapped lines, moved operands; about 11 percent
load) and module 1's `mutatedSnapshotsLoadCleanOrAreRejected`.

## Headless CLI

`kajo run <file.kasm>... [--workers 1] [--heap MiB] [--entries N]
[--stress every,tiny,oneblock] [--verify]` loads the files into a fresh
image, sends `run: 0 of: 1` to nil and prints one line: `checksum=`, `ms=`
(the run, not the load), and the counters. `--workers` other than 1 is
refused until module 3. Public surface: `Headless.run`, `VMError`,
`FuzzEntry`, `FuzzDriver`. `just golden` runs the six fixture kernels
through it against their published checksums.

## Counters

`Interpreter.counters`: sends (bytecode sends, fallbacks included, not the
host's entry), cache misses, cache flushes, primitive calls and failures,
special-send fallbacks, errors, safepoint polls taken, collections
triggered (allocation failures, the collect and compact primitives,
safepoints). `kajo run` prints them with module 1's collections,
compactions, allocations and bytes.

## Unsafe surface

282 lines with `unsafe` in `Interpreter/` and `Loader/` (comments
excluded): Send 126, Dispatch 82, Interpreter 44, InterpreterState 22,
Stack 6, Opcodes 1 (the decode's bit cast), FuzzEntry 1; one in each fuzz
target. They are the stack and register pointers, the two cached bases, the
state pointer and the cache. `InterpreterState` is `@unsafe`; `Regs`,
`Machine`, `Stack` and `Interpreter` are `@safe` wrappers. The parser,
assembler, image loader, primitives, object model and VMError have none.
Module 1 gained `bytesBase` and `slotsBase` (two unsafe lines).

## Hot-path checks

`just arc-check` (`scripts/check-hot-path-arc.sh`) builds with
`swift build -c release -Xswiftc -enable-testing --scratch-path .build/release-testing`
and disassembles each function with
`xcrun objdump -d -r --no-show-raw-insn --disassemble-symbols=<symbol> <object>`.
It fails on any `swift_retain`/`swift_release` and checks that `interpret`
has exactly one indirect branch (`br xN`) and one jump-table relocation
(`lJTI`). Result on 2026-11-02, all zero ARC:

- module 1's 15 allocation and store functions, plus `bytesBase` (4
  instructions) and `slotsBase`;
- `interpret` (710 instructions; calls only the slow paths below), one jump
  table: `ldrb w10, [x9], #1; cmp w10, #0x1a; b.hi; adr; ldrh; add; br`;
- `lookupMiss`, `lookupMethod`, `pollAndSend`, `pollAtJump`, `specialSend`,
  `primitiveSend`, `bottomReturn`, `stackOverflow`, `failAt`,
  `doesNotUnderstand`;
- `primitive`, `primAt`, `primAtPut`, `primBasicNew`, `primDivide`,
  `Machine.allocate`, `Machine.allocateBytes`, `Machine.fail`.

ARC exists by design in the pause operations (`Machine.collect`, `compact`,
`become`, `allocateSlow`, `rootsForPause`): they build Swift arrays for
module 1's root interface. They are `@inline(never)` so that ARC stays out
of the primitives and polls that call them (it leaked into `primitive`
before).

## Measurements

`fib` on one worker, `kajo run prelude.kasm lib.kasm fib.kasm` against
experiments/concurrent-young's `cy-bench kernel fib 1` (its default
configuration, built release into a scratch directory), same machine (M2
Max, 12 cores), five runs interleaved, 2026-11-02 18:46. Load average 4.2
(1 min) falling from 13 (5 min) after a ThreadSanitizer run; Firefox,
Warp and an agent were the busiest other processes, at 5 to 15 percent of
one core each.

| run | kajo ms | cy-bench ms |
|--:|--:|--:|
| 1 | 1642.3 | 1580.6 |
| 2 | 1637.5 | 1581.3 |
| 3 | 1637.7 | 1606.1 |
| 4 | 1667.7 | 1607.2 |
| 5 | 1661.6 | 1604.8 |
| **median** | **1642.3** | **1604.8** |

kajo / cy-bench = 1.023, within the brief's 10 percent. cy-bench's poll
also counts down a preemption budget (ADR 0004) that kajo does not have yet;
kajo counts sends and keeps frame links as offsets. Single runs earlier the
same day, same order: sends 2424 against 2276 ms (1.06), arith 2408 against
2696 (0.89), ivars 1957 against 1904 (1.03). Before `Opcode.decode` replaced
`Opcode(rawValue:)` fib took 2410 ms.

All six kernels through `just golden`: arith 2464, fib 1661, sends 2474,
alloc 2462, ivars 2001, walk 3427 ms, every checksum the published one.

## Decisions made while building

- **Frame links are offsets and indices**, not tagged addresses
  (SPEC-SHARED and the brief said tagged addresses). With bytecodes that
  move under compaction, a saved raw pc would need fixing at every
  compaction, which is what the experiment's `compactPcsFixed` did. Offsets
  need nothing; the cost is one add at return.
- **The lookup cache is per interpreter**, which is per worker from module
  3 on, rather than per stack.
- **Structural classes are sealed** (above). Not in the brief; without it a
  Smalltalk program could rewrite a verified method.
- **`push_ivar`/`store_ivar` are checked at run time** against the
  receiver's header, because of `become:`.
- **The stack-depth verifier is a dataflow pass**, not SPEC-SHARED's linear
  scan, which is unsound for untrusted input (a loop that pushes would
  outgrow `maxStack`).
- **Primitives get a `Machine` and copied arguments**, never the stack
  pointer, so they hold no raw address at all.
- **Primitive 8 `become:`** is in the v0 list (the ported
  `interpreterSeesBecome` needs it); **18 `==` and 19 `identityHash`** are
  new numbers.
- **`Message` is well-known class 12**, user classes start at 13.
- **The loader accepts any primitive number 1...255**; unimplemented ones
  fail, so the experiments' `lib.kasm` (which declares primitives 9 to 17)
  loads unchanged.
- **A load is all or nothing** except for `heapFull`.
- **Symbols are rooted for good** in the registry, one root each; the host
  keeps names, the heap keeps ids.

## Tests

60 test functions in this module (121 with module 1), green in debug,
under load (12 `yes` processes, load average 13), and under
`swift test --sanitize=thread` (170 s; also under load, at 119 tests, before
the last two were added). `just test-release` runs
the suite in a release build, which adds `goldenKernelChecksums` (the six
full-size kernels, 5 s).

Ported: `smallProgramRuns`, `kernelsAssemble`, `interpreterSeesBecome`, the
live-frames half of `compactionMovesMethodsUnderLiveFrames` (garbage below
the methods, a compaction from 50 frames deep; the running method's
bytecodes and literals move and the run and a second run are right),
concurrent-young's `result` register rule
(`theResultRegisterIsARootOnlyWhileLive`), the lookup cache across a
collection (`theLookupCacheIsFlushedAtEveryCollection`).

New: the opcode table and decode; the assembler's encoding, jump offsets
and literal frame; 23 assembler and 14 parser rejections; loader rejections
(unknown class three ways, duplicate class and method within and across
files, superclass cycle, shrinking subclass, ivar outside the class or in a
structural class, too many classes and methods, oversize method, too many
literals); a rejected load changes nothing; loading under a collection at
every allocation; special sends and their fallbacks; primitives and 21
argument checks; primitive failure into the body; a test per VMError kind;
the backtrace after an overflow; a collection inside a method; a load
flushes the cache; the safepoint switch; the kernels scaled down against
Swift models of them (the models reproduce the published checksums), under
a collection at every allocation (alloc 8 384 and walk 4 282 collections,
verifiers once at the end) and tiny entry chunks; the headless entry; 3 000
seeded mutations.

Waiting: everything with more than one worker, Processes, Semaphores,
budgets and events (module 3), including `operationsWhileOtherWorkersRun`
and `aFramePinnedObjectIsNotMoved` with a real frame; everything
generational and concurrent (modules 4 to 7).
