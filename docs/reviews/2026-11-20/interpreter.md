# Review 3: interpreter (the execution engines and the object model) at 821f20f

2026-11-20. Read only: no build, no test, no benchmark was run. Every number
below is from a file that already existed (named where used) or is written
as the measurement to make.

Area: `Sources/KajoVM/Interpreter/`, `ObjectModel/`, `Loader/`, `Native/`,
`Sources/KajoAOT/`. Every directory of it is in the core tier, so every
change below owes the 21 gates, `just arc-check`, the aligned A/B and the
device rows, unless the finding says otherwise.

Two existing measurements carry most of the ranking:

- `~/kajo-scratch/fused-sends/part1/counts/kernel-tests.txt` (the counting
  build of 2026-11-17, the kernel tests, one worker): 984.0 M dispatches;
  `send` 74.3 M; `value` 0.9 M, `value1` 29.3 M, `value2` 1.7 M; `at` 32.0 M;
  `at_put` 10.2 M; `size` 10.0 M; `class_of` 2.9 M; `push_tv_slot` 4.1 M,
  `store_tv_slot` 0.7 M; `push_closure` 6.5 M; `nonlocal_return` 0.75 M;
  `eq` 15.9 M and `fused_eq_jump_if_false` 7.2 M.
- `~/kajo-scratch/fused-sends/part1/count-runs.txt` (the run lines of the
  same build): primitive calls against sends: `sends` 40.0 M of 80.0 M,
  `walk` 62.9 M of 96.5 M, `alloc` 42.0 M of 125.9 M, `closures` 60.1 M of
  60.3 M, `collections` 16.8 M of 57.1 M.

So in this workload a block activation happens 0.43 times per send, an
instruction that runs out of line (`specialSend`, `v1Instruction`,
`pushClosure`) about 0.9 times per send, and in the kernels a primitive runs
for a third to all of the sends. The interpreter-speed module tuned the send. These three paths are as
frequent and were not looked at.

## The findings, in the order I would do them

| # | id | one line | expected gain |
|--:|---|---|---|
| 1 | interpreter.M1 | Float arithmetic tries the integer path first; SmallInteger op Float allocates a Swift array; a pure computation is wrapped in save and restore | `floats` kernel 2 times or more in both engines (inferred from the path; the kernel exists) |
| 2 | interpreter.M2 | The primitive call: save, two to four switches, restore, 6 words back through memory, for primitives that cannot pause; natively also a full continuation resolve | `sends` and `walk` (half and two thirds primitive sends): 10 to 25 percent interpreted, more natively where `walk` is at 1.06 times the interpreter (inferred) |
| 3 | interpreter.M3 | `nativeContinue` resolves the frame from the tables (about 14 loads) before it tests the common answer "same frame, expected pc" | every native slow call; `st-closures`, `collections` natively a few percent (inferred) |
| 4 | interpreter.M4 | The image loader at every launch: the pool lock per `isUsedReference`, block methods verified once per nesting level and once more, a Swift String per send site, host tables nothing reads, a SHA-256 per method at bind | image open is 40 ms of a 230 to 250 ms Release launch on the Mac; half of it looks avoidable (inferred) |
| 5 | interpreter.M5 | Instructions that run out of line re-derive `code` and `lits` (5 loads), decode the opcode twice, and block `value` goes through the arithmetic tier's tests | 66 M such instructions against 74 M sends in the kernel tests; a few percent of cycles there (inferred) |
| 6 | interpreter.M6 | Byte primitives work byte by byte through the entry; the byte replace does a seq_cst store and a seq_cst load per byte | the stream part of `collections` (9.2 times Pharo), String compare, hash, concatenation (inferred) |
| 7 | interpreter.M7 | A native send loads the activation from a second table after the cache hit; the cache line is 24 bytes and one in four straddles two cache lines | one dependent load less in front of every native send's indirect branch (aot.md lists it as not measured) |
| 8 | interpreter.A2 | The generator writes layout facts as literals the layout hash does not cover (the barrier word's offset, the frame's 4 and 5, the group and resume strides) | a change of the flag line or the frame cannot silently break native stores |
| 9 | interpreter.A1 | Ten primitive tables that nothing reads; the real map is nested switch ranges plus 113 `argc` guards | one table; the seam M2 needs |
| 10 | interpreter.A3 | Twelve interpreter counters are counted and never printed; closure homes and detaching returns have no counter | the numbers M8 to M10 lack |
| 11 | interpreter.R1 | One rule, two or three implementations, across the engines and inside each | drift caught at the change, not by a random program |
| 12 | interpreter.R2 | The class object, the method-install rules, literal making and six small helpers written two to seven times in the loader and the live primitives | a class-layout change becomes one place |
| 13 | interpreter.M8 | Three counter increments and the countdown per native call | at most a few percent of native `fib`; a switch to bound it exists |
| 14 | interpreter.M9 | A block with `^` costs its method a Context, barrier stores per temp and an out-of-line return | unknown: no counter; count first |
| 15 | interpreter.M10 | The method cache: flushed whole at every stop, hashed by XOR of two dense integers, bypassed by `perform:` and `respondsTo:` | unknown on a real workload; three counters first |

Findings by kind: 10 mechanical, 3 architecture, 2 reuse.

---

## interpreter.M1: Float arithmetic takes the integer path first

**Where.** `Sources/KajoVM/Interpreter/Special.swift:26-47`
(`specialFastPath`), `Sources/KajoVM/ObjectModel/Numbers.swift:327-371`
(`integerArith`), `:377-378` (`largeArith`), `:237-243` (`bigInt`), `:28-31`
(`BigInt.init(_: Int64)`), `:418-443` (`floatArith`, `arith`),
`ObjectModelPrimitives.swift:57-68`.

**What is there now.** A special send whose operands are not two
SmallIntegers calls `specialSend`, which calls `specialFastPath`. That
saves the registers, then calls `Machine.arith`:

```swift
func arith(_ op: ArithOp, _ a: Oop, _ b: Oop) -> Oop {
    let r = integerArith(op, a, b)
    if r != .none || failed { return r }
    return floatArith(op, a, b)
}
```

`integerArith` sends every pair that is not two SmallIntegers to
`largeArith` (`@inline(never)`), which begins
`guard let x = bigInt(a), let y = bigInt(b)`. For a SmallInteger `a`,
`bigInt` builds `BigInt(v.smallIntegerValue)`, whose initializer makes the
array `[UInt32(...), UInt32(...)]`. Only then is `b` found to be a float
and the array dropped.

**The cost.** Per float operation: one out-of-line call that can only
answer "not integers"; `save` (3 dependent loads to turn the pc into an
offset, 7 stores) and `restore` (about 7 loads) around a computation that
cannot pause when the result is a SmallFloat; the result registers through
memory. Per SmallInteger op Float (`i * 0.25`): also one Swift array
allocation and release, that is a `malloc` and a `free` on the special-send
path. `Numbers.swift:14-16` says the hot paths never reach `BigInt`; mixed
arithmetic does. The `floats` kernel
(`Tests/KajoVMTests/Fixtures/kernels/floats.kasm`: 30 M iterations, two
float multiplies of which one is integer times float, one add, one compare)
takes 2998.8 ms interpreted and 2683.1 ms native (`docs/modules/aot.md`,
"The bar"): about 100 ns an iteration for four float operations and eight
other dispatches, and the native engine gains 1.12 times because the time
is in this tier, which both engines call.

**The proposal.** In `specialFastPath` and in primitives 60 to 69, before
any save: when either operand is a SmallFloat and the other a SmallFloat or
a SmallInteger, decode, compute, and when the result encodes as a
SmallFloat (or is a Boolean) write it and return without save or restore.
Save and allocate only to box. Make `integerArith` call `largeArith` only
when one side is a LargeInteger object (one class test), never for a float.
The native engine gets it through `special` unchanged; a later step can
give it a pure `vt` entry (see M2).

**Bound and measure.** The change is its own bound: it is about 30 lines.
Measure the `floats` kernel in both engines in the aligned A/B, 1 and 8
workers, checksum equal; read `floatsBoxed` (once A3 prints it) to see the
boxed share. `just arc-check` does not see today's allocation: it is behind
`largeArith`, which is `@inline(never)` (I did not read whether the script
lists it). After the change no float operation calls it.

**Risk and size.** Touches no protocol. The rule "a save before anything
that can pause" holds because the new path neither allocates nor polls.
Guarded by `FusionTests` (a Float compare), the golden `floats` checksum,
the random programs. Small.

**Confidence.** Read (every line of the path). The factor is inferred.

---

## interpreter.M2: The primitive call path

**Where.** `Sources/KajoVM/Interpreter/Send.swift:327-376`
(`primitiveSend`), `:43-59` (`save`), `:64-76` (`restore`);
`Interpreter/Primitives.swift:28-63` (`primitive`);
`ObjectModel/ObjectModelPrimitives.swift:55-127`; `Strings.swift:326`;
natively `Sources/KajoAOT/Generator.swift:593-599`,
`Native/NativeInterface.swift:188-195` and `:86-109`.

**What is there now.** Every primitive runs the same way:

```swift
unsafe save(s, pc, sp, fp, hdr)
unsafe s.pointee.counters.primitiveCalls &+= 1
unsafe s.pointee.sendLength = length
...
unsafe s.pointee.readOnlyFailure = .none
let result = primitive(prim, m, call)
...
    return unsafe restore(s)  // the primitive may have paused: re-derive the bases
```

`primitive` is a `switch` over ranges that calls `objectModelPrimitive`
(a second `switch`), which for 120 to 136 calls `stringPrimitive` (a
third), and for 40 to 57 `integerOp` then `integerArith` (a third and a
fourth). A native send of a primitive method goes `kn_A<k>` to
`VT(s)->invoke` to `nativeInvoke` (`nCode`: 3 loads; `regsAt`: 5 loads) to
`invoke` to `primitiveSend` and back through `nativeContinue` (M3).

**The cost.** Per primitive call, interpreted: 3 dependent loads and 9
stores before the primitive, two to four switches, about 7 loads after it,
6 words stored and loaded for the result registers. That is paid by `at:`,
`at:put:`, `==`, `class`, `identityHash`, `basicSize`, `byteAt:`, integer
compares and every other primitive that reads its arguments and answers,
none of which can allocate, poll or suspend. Frequency: a third to all of
the sends of five kernels (the table at the top). Evidence that it
dominates: natively `fib` runs 3.43 times the interpreter and `walk`, two
thirds primitive sends, 1.06 times (3600.8 to 3382.4 ms), `sends` 1.79.

**The proposal.** Three steps, each measurable alone.

1. One table by primitive number (A1): the function, its argument count,
   and a trait: `pure` (no allocation, no poll, no suspend, no read-only
   refusal record), `allocates`, `pauses`, `activates`.
2. In `primitiveSend`, a `pure` primitive runs before `save`: receiver and
   arguments from `sp`, the function through the table, and on an answer
   the result is written at `sp - argc` and the registers go back as they
   came (with M5's change, without re-deriving `code` and `lits`). On
   failure the existing path runs.
3. In the generator, `kn_A<k>` of a method whose primitive is `pure` calls
   one new `vt` entry `prim_pure(s, number, sp, argc) -> u64` and on a
   nonzero answer stores it in `fp[0]` and tail-calls `kajo_resume[d]`: no
   `nCode`, no `regsAt`, no `nativeContinue`. Zero falls to `invoke`.

**Bound and measure.** A cheating build first: `primitiveSend` skips `save`
and `restore` for primitives 1 and 2 only (the kasm kernels' `at:` and
`at:put:`) and answers `regsAt`. Aligned A/B, `sends` and `walk`, cycles
per send, 1 worker. If under 5 percent on both, stop. After: the same
kernels, `collections`, the kernel tests' cycles, and natively
`nativeSlowCalls` per send before and after.

**Risk and size.** The trait is a promise. A `pure` primitive that
allocates or polls runs a collection with stale saved registers and loses
roots. Guard it in the checked build: `Machine.allocate*`, `pollSlow`,
`stopWorld` and `refuseReadOnly` trap when the running primitive's trait
is `pure` (one byte in the state, set and cleared in `primitiveSend`).
The random programs and the verifiers at every stop are the net. The
native half adds a `vt` entry (format version bump, layout hash).
Medium.

**Confidence.** Read for the path and the counts. The gain is inferred.

---

## interpreter.M3: `nativeContinue` resolves what it already knows

**Where.** `Sources/KajoVM/Native/NativeInterface.swift:86-109`
(`nativeContinue`), `:74-78` (`nativeStepping`), `:52-69`
(`nativeResume`).

**What is there now.** Every wrapper but the polls ends in
`nativeContinue(s, r, h0, expected)`. It runs, in this order:
`nativeStepping` (loads `w.vm`, `w.record`, the record's address, its
`stepMode`), then `nativeResume` (the native table, the method's group
line, `codeLen`, the depth table and `depths[pc]`, the `rx` table and
`rx[pc]`, the module, its resume table, the entry), and only then:

```swift
if unsafe r.hdr - base == h0 && UInt64(r.pc - r.code) == expected { return unsafe nativeCont }
```

**The cost.** About 14 loads, several dependent and in tables far from the
frame, on every `special`, `exec`, `invoke`, `send_slow`, `ret` and
`overflow` call, when the usual answer is "the same frame at the next pc".
In generated code that is every `at:put:`, `size`, `class`, block creation,
float operation and primitive send.

**The proposal.** Test the common case first. The generated code knows the
depth after the instruction, so pass it with the pc (`expected | depth <<
32`). When `r.hdr - base == h0`, the pc is the expected one and
`r.sp == r.hdr + 4 + depth`, answer `nativeCont` at once: the generator
emitted that continuation, so it is a resume point by construction. Keep
`nativeResume` for every other answer. Replace `nativeStepping`'s four
loads by one byte in `w.native`, written where the worker itself learns
that its Process steps (the slice's start and `pollSlow`, where stepping
is decided today).

**Bound and measure.** Counter: `nativeSlowCalls` is on the run line.
Cheating build: answer `nativeCont` when `hdr` and pc match, skipping the
stepping test (wrong only for a stepped Process), and run `st-closures`,
`collections` and `floats` natively in the aligned A/B.

**Risk and size.** Rules 4 and 11 of `docs/modules/aot.md`.
`aSteppedProcessRunsInterpreted`, `anUnboundCalleeRunsInterpretedAndItsReturnSwitchesBack`
and the native random programs guard them. Where `stepMode` is written
(`Processes/Debugging.swift:112-116`, `:265`) must be listed against the
new byte: I did not read whether another thread can set it while the
Process runs. Small.

**Confidence.** Read for the cost. Inferred for the stepping byte.

---

## interpreter.M4: What a sealed image pays at every launch

**Where.** `Sources/KajoVM/Loader/ImageFile.swift:159-191` (`Image.load`),
`:195-371` (`verifyImage`); `ObjectMemory/ObjectMemory.swift:342-351`
(`isUsedReference`, `highWater`);
`ObjectModel/ObjectModelPrimitives.swift:336-429` (`verifyHeapMethod`);
`Loader/Image.swift:109-138`; `Native/NativeBinding.swift:164-205`;
`Native/NativeLayout.swift:169-198`.

**What is there now.** Five things, each small.

1. `isUsedReference` reads `highWater`, and `highWater` takes the pool
   lock:
   ```swift
   var highWater: UInt64 {
       lockPools()
       defer { unlockPools() }
       return unsafe pools.pointee.highWater
   }
   ```
   `verifyImage` calls it for every entry of the heap and several times
   per class, dictionary entry, Symbol, method and literal
   (`ImageFile.swift:198-202`), although it read `hw` once at `:197` and
   no VM exists yet.
2. The method table holds every CompiledMethod, block methods included.
   `verifyImage` verifies each (`:355-363`), and `verifyHeapMethod`
   verifies every block literal of what it is given
   (`ObjectModelPrimitives.swift:418-424`). A block nested d deep is
   verified d + 1 times.
3. For every `send` instruction the verifier's literal closure copies the
   selector's bytes to a Swift array, validates a `String`, and runs
   `isSelector` and `arity(of:)` on it (`:397-403`). The same selector is
   decoded again at its next send site.
4. `Image(restoring:)` rebuilds `methods`, `methodKeys` (one interpolated
   `String` per method, `Image.swift:135`) and `classesByName`. Only the
   kasm loader and the image build read `methodKeys` and `methods`.
5. `bindNative` computes `nativeMethodHash` for every method: the
   bytecodes copied out byte by byte, decoded to an array of instructions,
   a byte array built with appends, SHA-256.

**The cost.** Measured: a Release launch on the Mac
(`~/kajo-scratch/native-by-default/part3/roundtrip/console-release-launch-*.log`)
reaches `host-ready` at 120 to 128 ms, `image-opened` 40 ms later and the
first frame at 230 to 250 ms; `bind_ms` is 5.2 to 5.4 of the 40. Not
measured: the split of the other 35 ms. Inferred: several hundred
thousand lock and unlock pairs (item 1), a third more bytecode
verification than needed for 3276 methods of which about 1080 are blocks
(item 2), about one `String` per send site (item 3), 3290 `String`s
(item 4).

**The proposal.** In order: (1) `verifyImage` and `verifySavedProcesses`
use a local `used` over the `hw` they hold, no lock. (2) Verify from the
method table only and have the recursion check that a block literal is
in the table, or skip block methods in the table loop once reached from
their method. (3) Memoize `LiteralInfo` per literal oop for one load.
(4) Build the host tables on first use by the kasm loader. (5) For a
sealed image, let `kajo aot` write the image's (method oop, group) pairs
and a digest of the image file into the module, and bind by one digest
compare. That changes rule 10 ("binding is by content") from per method
to per image for sealed images only: the owner's decision.

**Bound and measure.** Before anything: sub-steps in the launch trace
(`launch step=`): file read, snapshot load, each section of
`verifyImage`, `Image(restoring:)`, VM start, bind. On the Mac, the
iPhone and the iPad, Release, five launches. Decide per item from the
split. After: the same trace; `Image.load` p50 as
`docs/modules/image-processes.md:280` measured it (12.7 ms for a 2.6 MB
image then; the image is 6.6 MB now).

**Risk and size.** The loader is a trust boundary: items 1 to 4 remove no
check. `just fuzz snapshot` and the image fixtures guard it. Item 5
touches ADR 0015. Small for 1 to 4, medium for 5.

**Confidence.** Read for each item. The shares of the 35 ms are guesses
until the trace has sub-steps.

---

## interpreter.M5: Out-of-line instructions re-derive what the loop held

**Where.** `Sources/KajoVM/Interpreter/Send.swift:296-304` (`specialSend`),
`:309-319` (`regsAt`); `Special.swift:22-87` (`specialFastPath`),
`:399-464` (`v1Instruction`); `Dispatch.swift:182-232` (the callers);
`ObjectModel/Closures.swift:15`, `:51`.

**What is there now.** A slow path takes `pc, sp, fp, hdr` and answers all
six registers. `code` and `lits`, which the loop had in registers, are
rebuilt:

```swift
let method = unsafe Oop(raw: hdr.pointee)
return unsafe Regs(pc: pc, sp: sp, fp: fp, hdr: hdr, code: om.bytesBase(om.load(method, MethodLayout.bytecodes)),
                   lits: om.slotsBase(om.load(method, MethodLayout.literals)))
```

`v1Instruction` decodes the opcode a second time with its own `switch`.
`size` goes `v1Instruction`, then `specialSend`, then `specialFastPath`.
A block's `value` goes `specialSend`, `specialFastPath`, the test
`ArithOp.special(index)`, a second `switch`, and then `activateClosure`.
The loop's `at` fallback calls `v1Instruction`, whose `at` arm repeats
the test the loop just failed (`Special.swift:417-427`) and then calls
`specialSend`.

**The cost.** Per such instruction: 5 loads for `regsAt` (the frame's
method, its state word, a slot, the slot's object's state word, twice
over), a second indirect branch, one or two extra calls, and 6 words
stored and loaded for the answer. The existing disassembly
(`~/kajo-scratch/fused-sends/part2/disasm/base.s`) shows the last part:
57 call sites each with its own 48-byte result slot (`add x8, sp, #...`,
then six `ldr`), and a frame of 2944 bytes (`sub sp, sp, #0xb80`).
Frequency in the kernel tests: `value*` 31.9 M, `at_put` 10.2 M, `size`
10.0 M, the temp-vector slots 4.8 M, `class_of` 2.9 M, `push_closure`
6.5 M: 66 M against 74.3 M sends. In `collections`: 90 M of 1462 M
dispatches, 29 M of them temp-vector slots.

**The proposal.** (a) `specialSend`, `v1Instruction`, `pushClosure` and
`pushNewArray` take `code` and `lits` as two more scalars (eight register
arguments) and answer them unchanged when they did not save; `restore`
stays wherever they did. (b) `value`, `value1`, `value2` call their own
`closureValue(s, pc, sp, fp, hdr, argc, code, lits)`: the closure test
and `activateClosure`, else `specialSend`. (c) `size`, `class_of`, `ne`
and the two temp-vector instructions each call their own function; the
loop's `at` fallback calls `specialSend` directly, as `at_put` does.
`interpreter-speed.md` lists (c) under "Not done" as not in a kernel's hot
loop; the counts above are what it did not have.

**Bound and measure.** Build (a) for `specialSend` alone first, and read
the disassembly before the bench: the fused-sends module found that 24
instructions moved `true` and a base register. Then the aligned A/B on
`st-closures`, `closures`, `collections` and the kernel tests. Stop if
`interpret` spills a hot register.

**Risk and size.** The register allocation of `interpret` (`just
arc-check`: one jump table, one indirect branch; the disassembly diff).
The rule that `code` and `lits` are re-derived after any call that can
pause: a slow path that saved must answer `restore(s)`. `nativeExec`
(`NativeInterface.swift:231-278`) calls the same functions and must
follow. Medium.

**Confidence.** Read. The gain is inferred from counts, not measured.

---

## interpreter.M6: Byte work goes byte by byte through the entry

**Where.** `ObjectMemory/ObjectMemory.swift:305-318` (`loadByte`,
`storeByte`), `:259-267` (`storeByteChecked`);
`ObjectModel/Strings.swift:92-98` (`copyBytes`), `:346-351` (compare),
`:384-385` (scalar count), `:441-447` (search);
`ObjectModel/Symbols.swift:33-62` (`bytes(of:)`, `byteObjectHash`,
`sameBytes`); `ObjectModel/LongBytes.swift:378-384`, `:423-426`
(`primReplaceBytes`); `Numbers.swift:253`, `:267`, `:283`;
`KernelPrimitives.swift:149`; `LiveMethods.swift:374`, `:396`;
`Loader/Image.swift:234`.

**What is there now.** Every byte is read with `loadByte(o, i)` and
written with `storeByte(o, i, v)`. Each loads the object's state word
again (a relaxed atomic load, which the compiler does not merge: the
AGENTS.md lesson of the method's state word read five times). The byte
replace up to a chunk does this per byte:

```swift
for x in 0..<k { unsafe checkedStoreByte(st, rcv, j &+ x, om.loadByte(src, i &+ x)) }
```

that is `ldr`, `ldrb`, `ldr`, `stlrb`, `ldar`, compare, per byte. Only
objects past 256 KiB that are both large get `memmove` and `memcmp`.

**The cost.** Per byte: one or two extra loads on every read and copy; on
`replaceFrom:to:with:startingAt:` a seq_cst store and a seq_cst load. A
WriteStream that grows its 1 KiB buffer pays about 6000 instructions and
1024 ordered stores where a `memcpy` is tens of instructions.
String `=`, `<`, `hash`, `,`, `copyFrom:to:`, `asSymbol`, `indexOf:`
and a boxed Float's 8 bytes all take this path. The stream part of
`collections` is 9.2 times Pharo and the Dictionary part runs at 11.6
cycles a bytecode (`docs/performance/README.md`, section 5).

**The proposal.** One helper in the object memory for a stretch with no
poll: the body address from one state-word load, valid for reads until
this worker's next poll (module 6 frees an old body only after every
mutator's epoch has advanced, and a relocated body's old copy is not
written again). Compare, hash, search, count and copy-out use it with
`memcmp`, `memchr` or a word loop. A fresh object nobody else can see is
filled with `memcpy` from it. A replace into an existing object takes the
hazard slot as `primReplace` does for pointers
(`Relocation/Hazard.swift`), then `memmove`. Boxed Floats read and write
one 8-byte word.

**Bound and measure.** A cheating build: `copyBytes`, `sameBytes`,
`byteObjectHash` and the replace through raw pointers, run with `--reloc
off --young stw` (where it is correct), on the comparison's
`collections-stream` and `collections-dict` parts and the kernel tests.
If the stream part moves under 10 percent, stop. After: the same parts
in the product's modes.

**Risk and size.** The epoch argument for reads is mine, not the
model's: `docs/models/relocation.md` has a step for one slot read from a
state word just loaded, not for n bytes from one load. Add the step and
its switch before building. ThreadSanitizer sees the relocator's copy
against these reads; both are reads of the old body. The hazard half
reuses a modelled protocol. Medium.

**Confidence.** Read for the cost. Inferred for the epoch argument.

---

## interpreter.M7: The native send's activation is one load behind the cache hit

**Where.** `Sources/KajoAOT/Generator.swift:555-563` (`k_send`),
`:953-964` (the inline send); `Interpreter/InterpreterState.swift:99-103`
(`CacheEntry`), `:162`; `Interpreter/Send.swift:236-243` (`lookupMiss`);
`Native/NativeBinding.swift:193-195`.

**What is there now.** A native send probes the lookup cache, then loads
the method's line of the method-to-native table:

```c
if (LIKELY(*(const u64 *)(e_ + CACHE_CLS) == cls_ && *(const u64 *)(e_ + CACHE_SEL) == sel_)) m_ = *(const u64 *)(e_ + CACHE_METHOD);
else m_ = VT(s)->lookup(s, cls_, sel_);
KF *act_ = *(KF *const *)(AT(s, W_NTAB, const char *) + m_);
```

A cache line is three words, 24 bytes, so with 64-byte cache lines two
entries of every eight span two of them.

**The cost.** Per native send, a chain of dependent loads in front of an
indirect branch: the receiver's header, the cache entry, the table line
(in a table as large as the object table, 16 bytes an entry, its lines
unrelated to anything else the send touched), then `br`. When the branch
is mispredicted, the chain's length is the time to recover.
`docs/modules/aot.md` names these loads "the floor of this design" and
lists the alternative under "Deviations": "the method-to-native mapping's
parallel-array candidate was not built or measured".

**The proposal.** `CacheEntry` becomes four words: class index, selector,
method, activation. `lookupMiss` fills the fourth from the table (0 when
there is none or no module). `k_send` branches on and through
`e_->activate`. Entries are 32 bytes and never straddle; the index is a
shift, not a multiply by 24. The interpreter ignores the fourth word. The
cache grows from 24 to 32 KiB a worker.

**Bound and measure.** The change is small enough to be its own bound.
Native `fib`, `sends`, `st-sends`, cycles per send (17.0, 39.2 and 24.5
today), aligned, both worker counts; the interpreter's kernels must stay
within noise (the probe's address arithmetic changes).

**Risk and size.** A line's activation must die with the binding of its
method: `ObjectMemory.unbindNative` (`NativeBinding.swift:236-240`) runs
in a stop, and every worker flushes its cache when it sees a stop
(`Workers/Safepoint.swift:116-122`), so the rule holds today; M10's
proposal to flush less would have to keep it. The layout hash already
covers the cache geometry. AOT 3's guarded direct calls remove the probe
for monomorphic sites; this stays for the rest. Small.

**Confidence.** Read.

---

## interpreter.A2: Layout facts in the generator that the layout hash does not cover

**Where.** `Sources/KajoAOT/Generator.swift:505` against
`Sources/KajoVM/Marking/MarkingState.swift:783-785`; `Generator.swift:601-610`,
`:625-638`, `:684`, `:786-788`, `:921-935`; `:516-525` against
`Native/NativeBinding.swift:30-39` and `Native/NativeInterface.swift:65`;
`Native/NativeLayout.swift:30-89`.

**What is there now.** The layout hash is the SHA-256 of
`NativeLayout.constants`. The generator also writes numbers that are not
taken from those constants:

```c
if (__atomic_load_n(AT(s, W_FLAG, u32 *) + 2, __ATOMIC_RELAXED) != 0) { VT(s)->store_barriers(s, o, i, v, site); return; }
```

The `+ 2` is `barrierWord(flag)`'s `flag + 2`, a fact of the marking
module. The frame is written as `h[0]` to `h[4]`, `hdr[4]`, `hdr + 4 +
depth` and `hdr[5 + i]`, though `FRAME_*` and `FRAME_HEADER_WORDS` are in
the constants. `KGroup`, `KResume` and `KModule` are declared in the C
prelude and mirrored by hand as `GroupOffset`, `ModuleOffset` and the
literal 16.

**The cost.** The hash proves that a module and a VM were built from the
same constants. It does not prove the generator used them. If the barrier
word moves in the flag line, the hash does not change, every native
`store_ivar` tests the wrong word, and stores made while marking skip the
SATB barrier: a lost object, found only if a native random program
happens to mark at the right time. A frame-header change needs about a
dozen hand edits in the generator.

**The proposal.** (1) Add the barrier word's offset (and the young
barrier's nursery mask shift if it is ever used) to
`NativeLayout.constants`, computed from the Swift declaration, and emit
it. (2) Emit every frame index from `Frame.*`. (3) Emit
`_Static_assert(sizeof(KGroup) == ...)` and `offsetof` asserts for the
three structs in the tables file, with the Swift side's offsets as the
right-hand sides, so `native-cc` fails when the mirrors disagree. (4) A
test that the generator's source holds no digit literal in a frame or
flag expression is the project's kind of test (the `ShellVM` table test);
cheaper: make the emitting helpers (`sp(_:)`, `flush`, `reload`) the only
place a frame index is written.

**Bound and measure.** No speed. The check is a broken variant by hand:
move `barrierWord` to `flag + 3` in a scratch tree and see which gate
fails today (my reading: none must, by construction) and after.

**Risk and size.** None to behaviour: the emitted text is the same. The
format version does not change. Small.

**Confidence.** Read.

---

## interpreter.A1: Ten primitive tables that nothing reads

**Where.** `static let table: [(number: Int, selector: String, argc: Int)]`
in `Interpreter/Primitives.swift:17`,
`ObjectModel/ObjectModelPrimitives.swift:26`,
`ObjectModel/KernelPrimitives.swift:25`, `ObjectModel/LiveMethods.swift:57`,
`ObjectModel/LiveClasses.swift:39`, `ObjectModel/InstancePrimitives.swift:65`,
`Shell/ShellPrimitives.swift:56`, `Processes/ProcessPrimitives.swift:11`,
`Processes/Debugging.swift:57`, `Nursery/Finalization.swift:23`; the real
map in `Interpreter/Primitives.swift:28-63`.

**What is there now.** Ten tables list each primitive's number, selector
and argument count. `grep` finds no reader of any of them in `Sources` or
`Tests`. The map that runs is `primitive`'s `switch` over ranges
(`case 40...79, 90...136: return objectModelPrimitive(n, m, c)`), a
second and third `switch` behind it, and 113 `c.argc ==` guards in the
primitive bodies.

**The cost.** Three places know a primitive's number and two its arity,
and the one written as data is the one nothing checks. A new primitive is
added to a range, a body with its own guard, a table nobody reads, and
by hand to `ExtremeIntegerTests`. "Which primitives can pause" is known
nowhere (M2 needs it). The kernel's `<primitive: n>` declarations are not
checked against any of it.

**The proposal.** One table of 256 entries in the interpreter: function,
argument count (or "any"), trait, name. `primitiveSend` checks the count
once and calls through it. The ten tables and the 113 guards go. A test
derives from it: every `<primitive: n>` method in `kernel/` and `tools/`
names an entry of its arity; `ExtremeIntegerTests` iterates the entries
whose trait says they take an integer. The module tables become
contributions to the one table (each module registers its range), so the
interpreter still does not know what a module's primitive does.

**Bound and measure.** The dispatch change is M2's step 1 and is measured
there. On its own: `just arc-check` (the table must be raw memory, not a
Swift array of closures: an array access is ARC and bounds traffic on the
send path) and the aligned A/B at parity.

**Risk and size.** A function pointer table in raw memory filled at VM
start; `@convention(thin)` functions or C-convention ones. The
interpreter's "one indirect branch" check does not cover `primitiveSend`.
Medium, mostly mechanical.

**Confidence.** Read (the grep is in this review's notes: no match for
any `…Primitives.table` outside its definition).

---

## interpreter.A3: Counters that are counted and not reported

**Where.** `Sources/KajoVM/Interpreter/InterpreterState.swift:21-56`;
`Sources/KajoVM/Headless.swift` (the run line);
`ObjectModel/Closures.swift:24-31`; `ObjectModel/Frames.swift:177-206`.

**What is there now.** `InterpreterCounters` holds `specialSendTier`,
`superSends`, `performs`, `closuresCreated`, `closureActivations`,
`contextsMaterialized`, `nonLocalReturns`, `unwindingReturns`,
`cannotReturns`, `readOnlyRefusals`, `largeIntegersMade`, `floatsBoxed`.
None of these names occurs in `Headless.swift`, `Workers/VM.swift` or
`Sources/kajo`; tests read them. The shells' rows carry no `cacheMisses`.
A closure made with a home Context (`pushClosure` calling `materialize`)
and a return that detaches a Context (`returnSlow`) are not counted at
all: `contextsMaterialized` counts `push_this_context` only.

**The cost.** M1, M9 and M10 and the LargeInteger note below have no
number from a real workload because of this. The project's rule is a
counter first.

**The proposal.** Give `InterpreterCounters` a `named` list as
`NativeCounters` has (`Native/NativeState.swift:51-56`) and print it from
that list on the run line and in the shells' rows, so a new counter
cannot be forgotten. Add `homesMaterialized`, `returnsDetaching`,
`cacheConflicts` (a miss that replaced a line holding another key) and
`lookupsUncached` (M10). All four are on slow paths.

**Risk and size.** `Headless.swift` is outside the core directories; the
four new counters are inside. `shell-report.py` must name the new keys
(the lesson of the unknown field values). Small.

**Confidence.** Read.

---

## interpreter.R1: One rule, two or three implementations

**Where, as pairs (Swift original, restatement).**

- class of a word: `Send.swift:188-192`, `Generator.swift:460-464`
- has a slot, may store: `Dispatch.swift:437-441` and `Special.swift:375-380`, `Generator.swift:465-469` and `:492-496`
- the store with its barriers: `Nursery/Barrier.swift:24-46`, `Generator.swift:504-515`
- the poll test: `Dispatch.swift:415-418` and `Send.swift:111-116` and `Special.swift:279-280`, `Generator.swift:470-474`
- the cache probe: `Send.swift:120-122`, `Send.swift:240`, `Special.swift:299-301`, `Generator.swift:556-559`, `Generator.swift:954-957`
- the activation's frame: `Send.swift:155-182`, `Generator.swift:601-611`
- a closure's frame: `ObjectModel/Closures.swift:68-109`, `Generator.swift:624-641`
- SmallInteger arithmetic and compares: `Dispatch.swift:115-170`, `Numbers.swift:330-342`, `Generator.swift:863-870`
- `at:` on an Array: `Dispatch.swift:185-198`, `Special.swift:417-427`, `Special.swift:49-71`, `Generator.swift:875-879`
- the plain return: `Send.swift:208-219`, `Generator.swift:916-937`
- opcode to slow-path function: `Dispatch.swift` (the cases), `Special.swift:331-367` (`extendedInstruction`), `NativeInterface.swift:237-276` (`nativeExec`)

**What is there now.** Rule 7 of the AOT module is "the same observable
behaviour", kept by tests that run both engines (the golden kernels, the
native kernel tests, the native random programs,
`everyLeverAnswersWhatTheInterpreterAnswers`). Only `k_store` carries a
comment naming what it restates. Inside one engine there are copies too:
the probe is written three times in Swift and twice in the generator;
`v1Instruction`'s `at`, `is_nil` and `not_nil` arms repeat what the loop
does inline and what the generator emits inline, so nothing reaches them
with a different answer.

**The cost.** A change to one side finds the other only if a test happens
to exercise the difference. Example: a new condition in
`storeWithBarrier` (a third barrier bit, a card mark) must be made in
`k_store`; nothing fails at build time, and the failure is a lost object
under a native run with the right timing. Example: changing the cache
hash (M10) must edit five places.

**The proposal.** Not one shared implementation: KajoVM has no C target by
decision, and the interpreter's loop is tuned by its disassembly.
(1) Inside each engine, one copy: a `@_transparent cacheLine(s, cls,
sel)` for the three Swift probes; one generator function emitting the
probe for both the helper and the inline send; the dead `v1Instruction`
arms removed with M5. (2) Across engines, a tripwire in the project's
style of a table test over the source: each C helper in the prelude is
emitted by a Swift function whose doc names its original
(`restates: storeWithBarrier`), and a test hashes the original's source
text and compares it with a hash recorded beside the restatement. A
changed original fails the test until someone has read the restatement
and updated the hash. (3) `nativeExec` takes each opcode's out-of-line
function from one table the dispatch loop's cases also name.

**Bound and measure.** No speed. The check: change one character of
`storeWithBarrier` in a scratch tree; today every gate passes without the
generator being opened.

**Risk and size.** The tripwire is test code only (Swift tier). The
de-duplication inside the interpreter is core and must keep `interpret`
identical (`@_transparent` does). Small to medium.

**Confidence.** Read.

---

## interpreter.R2: The loader and the live primitives write the same things twice

**Where.**

- a class object's slots: `Loader/Image.swift:271-294` (`fillClass`), `ObjectModel/LiveClasses.swift:283-313` (`defineClass`)
- a class pool: `Image.swift:729-749`, `LiveClasses.swift:271-282`
- the size and subclass rules: `Loader/ClassRules.swift:10-23` (used at `Image.swift:678`, `:709` and by `defineClass`), and inline again in the kasm loader's `check`, `Image.swift:452-466`
- planning a method install (the instance-variable rule, unknown class references, duplicates, the per-class limit): `Image.swift:477-507` and `:778-813`; one walks literal Arrays for class references (`classRefs`), the other does not
- the install's tail: `Image.swift:322-333`, `:817-826`
- a `Literal` to a heap object: `Image.swift:366-403` (`partLiteral`), `:889-927` (`codeObject`)
- a class oop to its checked index: `Interpreter/Primitives.swift:110-114`, `ObjectModel/LiveMethods.swift:83-86`, `:104-107`, `:158-160`, `LiveClasses.swift:126-132`
- the text of a Symbol or String: `Image.swift:165-170`, `KernelPrimitives.swift:137-142`, `LiveClasses.swift:113-117` (three different guards)
- a byte array into a fresh object: `Numbers.swift:253`, `Strings.swift:292`, `KernelPrimitives.swift:149`, `LiveMethods.swift:374`, `:396`, `Image.swift:234`
- eight little-endian bytes and a word: `Numbers.swift:266-268`, `:282-283`, `LiveMethods.swift:283-284`, `:291-292`, `Image.swift:385`, `:903`, `ImageFile.swift:144`, `:161-165`
- stop the world, note the epoch, flush the cache: `ObjectModelPrimitives.swift:285-291`, `LiveClasses.swift:97-107`, `InstancePrimitives.swift:136-152`

**The cost.** Module 8e wrote `ClassRules` so that "the primitive
re-checks what the build checks, with the same code"; the kasm loader
was left with its own copy, and the class object itself is still laid
out in two places. A new class slot, or a change of what a metaclass
holds, must be made in `fillClass`, in `defineClass` and in
`verifyImage`'s class rules, and only the last is a check. The two
install planners already differ.

**The proposal.** `ClassObjects.fill(om, class:, meta:, ...)` and
`ClassObjects.makePool` called by both; the kasm `check` through
`ClassRules`; one `MethodInstallPlan` for both planners; one
`ObjectMemory.behaviorIndex(_:)`; one `fillBytes(_:from:)` (with M6, a
`memcpy`); one `word64(of:)` and `setWord64`; one `Machine.inInstallStop`.
Do it with the next core change that touches these files, not as a
module of its own: it owes all 21 gates and gains no speed.

**Risk and size.** Refactors of cold code; the image fixtures, the Tonel
round trip (byte identity) and the live-class tests guard them. Medium
in lines, low in risk.

**Confidence.** Read, except `LiveClasses.swift` past line 330 and
`InstancePrimitives.swift`, of which I read parts.

---

## interpreter.M8: Three counters and the countdown per native call

**Where.** `Sources/KajoAOT/Generator.swift:553-563` (`k_send`: `k_due`,
`W_SENDS`, `W_NSENDS`), `:925` and `:933` (`W_NRETURNS`), `:639`.

**What is there now.** A native send decrements the countdown, increments
`counters.sends` and `native.counters.nativeSends`; a native return
increments `nativeReturns`. Each is a load, an add and a store on the
worker.

**The cost.** Four read-modify-writes of memory per call and return,
about 12 of the 113 instructions a native `fib` call costs
(`docs/modules/aot.md`, part 1). The interpreter-speed module bounded the
countdown alone at 1.1 percent of the interpreter's send; nobody bounded
these at the native engine's speed, where a send is 17 cycles and not 58.

**The proposal.** Keep `sends` (the gates compare it across engines).
Make `nativeSends` and `nativeReturns` a generator option, on for the
tests and the gates, off in a product module, or derive `nativeSends`
from `sends` minus the interpreter's own count.

**Bound and measure.** The switch exists: `AOTOptions.brokenNoSendCount`
removes one increment. Generate `fib` and `sends` with it and without,
aligned, five interleaved runs: that is one counter's price. Build
nothing if it is under 1 percent.

**Risk and size.** Tests that read the two counters
(`NativeEngineTests`) keep the option on. Small.

**Confidence.** Read. The gain is a guess until the switch is run.

---

## interpreter.M9: A block with `^` costs its method a Context

**Where.** `ObjectModel/Closures.swift:23-31` (`pushClosure`),
`ObjectModel/Frames.swift:88-107` (`materialize`), `:113-126` (`detach`),
`:177-206` (`returnSlow`), `:270-317` (`nonLocalReturn`); ADR 0009
sections 3 and 4.

**What is there now.** When a method creates a block that can return
non-locally, the frame's Context is materialized at once:

```swift
home = m.materialize(h)
```

From then on the frame's context word is not the empty one, so the
method's own return takes `returnSlow`, which detaches the Context: every
argument and temp is stored into it with the barrier, then three
`checkedStore`s (a seq_cst store and a seq_cst load each).

**The cost.** Per activation of a method such as `detect:ifNone:`, an
`at:ifAbsent: [^nil]` caller or a loop with an early `^`: one more
object of 8 + arguments + temps words beside the closure, a barrier
store per argument and temp, six ordered memory operations, and an
out-of-line return, whether or not the block ever runs its `^`. The
kernel tests ran `push_closure` 6.5 M times and `nonlocal_return` 0.75 M
times; how many of the 6.5 M materialized a home is not counted.

**The proposal.** Count first (A3: `homesMaterialized`,
`returnsDetaching`). If the count is a real share of sends, the design
question for the owner is ADR 0009's: the closure could carry a token
that names its home frame (an immediate of a spare tag in the frame's
context word, unique per activation), with the Context made only when
someone asks for it (`thisContext`, `BlockClosure>>home`, an unwind).
The non-local return already walks the frames between the block and its
home; it would stop at the frame whose context word holds the token.
That touches the frame's context word (the native engine's return by
lookup wants it empty), the saved-Process rules, `terminateTo:` and the
closure's shape in the image loader. I am not proposing it built before
the count says it matters.

**Bound and measure.** The two counters over the kernel tests, the tools'
tests and `collections`. A cheating build is not safe here (a missing
Context breaks `ensure:`).

**Risk and size.** The counters: small. The redesign: large, an ADR
change, a model of nothing concurrent but every reader of the context
word listed (`docs/modules/aot.md` has that list).

**Confidence.** Read for the path. The frequency is a guess.

---

## interpreter.M10: The method cache on a real workload

**Where.** `Workers/Safepoint.swift:116-122` (`noteEpoch`),
`Interpreter/InterpreterState.swift:414-423`, `:162`;
`Interpreter/Send.swift:120`, `:236-243`; `Interpreter/Special.swift:213-217`
(`isSelectorOf`); `ObjectModel/ObjectModelPrimitives.swift:95-98`;
`ObjectModel/Frames.swift:221`, `:226`; `Loader/Image.swift:562-583`.

**What is there now.** Three things, none measured outside the kernels,
whose programs miss 3 to 89 times a run.

1. Every worker clears all 1024 lines (24 KiB) when it sees a stop:
   ```swift
   if unsafe w.pointee.seenEpoch != epoch {
       unsafe w.pointee.seenEpoch = epoch
       unsafe Machine(state: w.pointer(to: \Worker.interp)!).flushCache()
   ```
   After it, the first send of every (class, selector) pair is a full
   lookup: per class of the chain the class object, its dictionary, the
   dictionary's header, and one or more probes, each probe reloading the
   dictionary's state word.
2. The line is `((sel >> 4) ^ cls) & 1023`: two dense small integers
   (Symbols interned in a row, classes numbered in pairs) combined by
   XOR. (sel, cls) and (sel ^ d, cls ^ d) share a line for every d.
3. `perform:` (`isSelectorOf`), `respondsTo:` and the VM's marked sends
   call `lookupMiss` or `lookupMethod` without probing the cache: a full
   lookup each time, and for `perform:` a counted miss, then the send
   probes the line just filled.

**The cost.** Unknown, and that is the finding. In the product's young
mode stops are few per marking cycle, so item 1 may be nothing there and
real under `young=stw` and under anything that stops per operation.
`interpreter-speed.md` lists "the global cache's misses after a pause"
under "Not done: not measured under the storm".

**The proposal.** (a) Counters first (A3): `cacheMisses` and
`cacheFlushes` in the shells' rows; `cacheConflicts`;
`lookupsUncached`. Run the kernel tests, the tools' tests and the storm
row in both young modes. (b) If item 1 shows: flush on a structure epoch,
bumped by the stops that can change a lookup's answer or free what a
line names (method install and removal, class define, redefine and
remove, freed class indices, become, the image's loads), not by every
stop. My reading is that a line's selector and method are kept alive by
the method dictionary that maps them, and methods and Symbols are old
and pinned; that reading must be checked against every stop kind before
anything is built, and M7's activation word would need the same epoch.
(c) If item 2 shows: a multiplicative mix of the selector before the XOR,
measured against the multiply's latency on the send's critical path.
(d) Item 3: probe first through the one `cacheLine` helper of R1.

**Bound and measure.** For (b), a cheating build that never flushes at a
stop, run on a kernel that installs nothing: its gain is the ceiling.

**Risk and size.** (a) and (d) small. (b) touches the invariant "a cache
line never names a freed or replaced method", which has no verifier
today because the flush at every stop made one unnecessary; it would
need one. Medium.

**Confidence.** Read for what the code does. Inferred for (b)'s safety.
The cost is unknown.

---

## Noted, not ranked

- LargeInteger arithmetic goes through `BigInt` (`Numbers.swift:17-232`):
  about five Swift arrays per operation (bytes out, limbs, the result's
  limbs, its bytes, each byte stored through the entry) and a bit-serial
  long division for a divisor of more than one limb (`:140-158`). The
  file says it is cold. It is hot for any program whose integers leave
  62 bits without leaving 64 or 128 (hashes, products). `largeIntegersMade`
  is not printed (A3). An `Int128` fast path for both operands under
  16 bytes would cover that case without arrays; count first.
- The symbol table's lookup (`Symbols.swift:78-90`) compares bytes with
  every Symbol of the bucket: per candidate the Symbol's header (for its
  count) and then its body, two dependent misses each. 1024 buckets; a
  development image of some 10 000 Symbols has about ten a bucket. A
  hash stored beside each Symbol in the bucket (a second slot) would
  make a non-matching candidate cost no miss. Matters for `asSymbol`,
  the compiler and the image build, not for running code.
- `interpret`'s frame is 2944 bytes because each of 57 call sites has
  its own 48-byte result slot (the disassembly named in M5). Harmless to
  time as far as I can tell; it is why M5(a) is about loads and not
  about the result's stores.
- The file primitives 148 and 149, `sourcesPath`, `writeTemporary` and
  `readFile` live in `ObjectModel/LiveClasses.swift:836-960`. They are
  not about classes. A file of their own would let the path rules be
  read in one place.

## Settled, not repeated

I read these and propose nothing against them: a per-site inline cache,
removing the countdown, fused sends, the leaner activation (both pieces:
the activation from the cache line and the return's bases from the
frame), the header-bit test in the store path, returns by lookup against
the marker, `-O2` against `-Os`, the subset `callees`. M7 is not the
leaner activation: it adds one word for the native engine and changes
nothing the interpreter's loop reads.

## Read and found good

- The dispatch loop's shape: one opcode per case, scalars into slow
  paths, registers back, `Opcode.decode` as one compare; the comments
  say why each register is where it is.
- Fused opcodes replace a first byte only. Every reader of bytecodes
  sees the plain instruction through `decodeInstruction`; there is one
  place where that is decided.
- One bytecode verifier (`verifyBytecodes`) behind the assembler, the
  image loader and the make primitive, and one `makeMethodObjects`
  behind the image build, the kasm loader and primitive 143. This is the
  sharing R2 asks for elsewhere.
- `NativeLayout.constants` computes worker offsets from the Swift
  declarations with key paths; no offset is typed by hand there.
- Binding by content with the layout hash; the driver above both
  engines; `interpret` untouched by the native engine.
- `storeWithBarrier` tests the SmallInteger bit first; `canStore` is two
  single-bit tests with the reason beside it.
- Interning: the lock-free lookup, the second lookup under the lock, the
  Symbol made whole before it is published.
- Primitives check each bound before any arithmetic on their arguments
  (`primReplaceBytes`, `primBasicNew`).
- The long byte primitives poll between chunks and re-read lengths after
  a park.

## Not read, or read in part

- `ObjectModel/LiveClasses.swift` past line 330 (redefine, remove, the
  file primitives): outline only.
- `ObjectModel/InstancePrimitives.swift`: lines 130 to 156 only.
- `Loader/SavedProcessRules.swift`, `Loader/KasmParser.swift`,
  `Loader/FuzzEntry.swift`, `Loader/KernelCompilerProbe.swift`,
  `Loader/KernelRun.swift`, `Loader/LoadError.swift`,
  `Interpreter/OpcodeCounts.swift`, `Interpreter/VMError.swift`: outline
  or not at all.
- `Sources/KajoVM/Relocation/Hazard.swift`, `Workers/` and `Marking/`
  beyond the few functions named above (other reviewers' areas).
- Docs read whole: `interpreter-speed.md`, records 20, 32, 37, 42. Read
  in part: `aot.md` (the "As built" half), ADR 0015, ADR 0009 (sections
  3 and 4 by search), `docs/performance/README.md` (sections 2 to 5),
  the second review's finding lists. Not read: `interpreter.md`,
  `object-model.md` beyond searches, `aot-product.md` and
  `native-by-default.md` beyond their records, `symbol-interning.md`,
  `large-objects.md`, records 01 and 38.
- No disassembly of the current head was read; the one used is the
  fused-sends module's base build of 2026-11-17.

## Bugs met on the way

None that a program can hit. Stale comments, and one comment that is
wrong about a hot path:

- `Sources/KajoVM/ObjectModel/Numbers.swift:14-16` says the hot paths
  never reach `BigInt` for SmallIntegers that do not overflow. A
  SmallInteger operand of a float operation does (M1).
- `Sources/KajoVM/Interpreter/Stack.swift:46-47` says the frame's
  context word is "nil ... never read yet". It is SmallInteger 0 and
  every return reads it (`:61-65` of the same file say so).
- `Sources/KajoVM/ObjectModel/Symbols.swift:5-10` describes the symbol
  table as open addressing, at most half full, filled with the world
  stopped by `primIntern`. It is buckets of WeakArrays filled under the
  intern lock (`:155-170` of the same file); `Loader/Image.swift:253-254`
  names `primIntern` too.
- `Sources/KajoVM/Loader/Image.swift:495` checks class references in the
  top level of a method's literals only, where `:793-800` walks literal
  Arrays. kasm has no literal Array syntax, so nothing reaches the
  difference today.
- `Sources/KajoVM/Interpreter/Special.swift:294` and `:306`: `rcv` is
  read and then discarded with `_ = rcv`.
