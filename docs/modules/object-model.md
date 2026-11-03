# Module 8a: object model v1 in the VM

Status: built, 2026-11-03. The VM side of module 8 (`docs/modules/kernel.md`,
"8a, the VM side"): ADR 0009 sections 2 to 11 in `Sources/KajoVM`. New code
in `Sources/KajoVM/ObjectModel/` (closures, Contexts, returns and
unwinding, numbers, Strings and Symbols, read-only, the primitives),
`Interpreter/Special.swift` (the special sends' out-of-line tier, super,
the extension prefix, the activation primitives),
`Loader/BytecodeVerifier.swift` (the one bytecode verifier),
`Loader/ImageFile.swift` (the image format) and
`Processes/StackGrowth.swift`; changes to modules 1 to 7 listed below.
Tests in `Tests/KajoVMTests/ObjectModel/`, fixtures
`Fixtures/kernels/objectmodel.kasm` (the test kernel), `closures.kasm` and
`floats.kasm` (benchmarks), `Fixtures/fuzz/kasm/{v1,objectmodel}.kasm`,
`Fixtures/fuzz/snapshot/image.img`.

8b (the bootstrap compiler, `kernel/`, the image build, SUnit, the event
stream) is next and not started.

## What it hides

- How an immediate is encoded (SmallFloat, Character) and which words are
  references: one predicate, `raw & 0xF == 0`, everywhere.
- The bytecode encoding of set v1: numbering, operands, the extension
  prefix, stack effects and transient depths (`Opcodes.swift` only).
- What a frame records for a block and how a frame becomes a Context and
  stops being one.
- How a non-local return finds its home and when it asks the kernel to
  unwind; how `terminateTo:` cuts frames.
- How a class's format, metaclass and seal are represented.
- LargeInteger and Float representation and normalization.
- How Strings are stored, how Symbols are interned, and which positions are
  valid.
- How a stack grows.
- What an image file holds and what its loader checks.

## Immediates (ADR 0009 section 2)

| low bits | kind | payload |
|---|---|---|
| `...1` | SmallInteger | 63 bits, unchanged |
| `..10` | SmallFloat | 62 bits: the double rotated left by one (sign to bit 0), the exponent offset by 768 into nine bits |
| `0100` | Character | bits 4..63: a Unicode scalar (no surrogates, at most U+10FFFF) |
| `0000` | reference | unchanged |
| `1000`, `1100` | spare | rejected by the verifier, the snapshot and image loaders |

`SmallFloat.encode` (`ObjectMemory/Oop.swift`): `r = rotl(bits, 1)`, `x = r
- 768 << 53`; if `x - 2 < 2^62 - 2` the word is `x << 2 | 2`; zero (`r <= 1`)
is `r << 2 | 2`; anything else is boxed. Decoding reverses it. Every `..10`
word decodes. A SmallFloat holds exactly the doubles whose biased exponent
is 768 to 1279 (2^-255 to 2^257, about 1.7e-77 to 2.3e77) and both zeros,
with the full mantissa; plus or minus 2^-255 itself is boxed (its pattern
is zero's), as are subnormals, NaN and infinities. ADR 0009's open question
(is SmallFloat arithmetic exact after re-encoding?) is answered:
`smallFloatRoundTripsExactlyAgainstDouble` checks 200 000 doubles (half
random, half in range) against Swift's `Double` bit for bit, and the
encoding is a bijection on its range, so arithmetic is IEEE arithmetic.

### The "is it a reference" inventory

Every site that decides whether a word names an entry, from
`grep -rn '& 1\|isSmallInteger\|objectTagMask\|isObject'` over
`Sources/KajoVM` at the final commit. "Full" is `raw & 0xF == 0` (with
`!= 0` for `Oop.none` where a slot can hold it), `isObject`, or
`isImmediate`.

| site | file | before 8a | now |
|---|---|---|---|
| insertion barrier fast path (`storeWithBarrier`) | Nursery/Barrier.swift | `v & 1 == 0` | full |
| post-store conflict's barrier (`storeConflict`) | Relocation/PostStore.swift | `v & 1 == 0` | full |
| flag-word store path (`storeWithBarriers`) | Marking/SATB.swift | `v & 1 == 0` | full |
| array copy loop and its broken variant (`copySlots`, `copyStoreUnordered`) | Relocation/Hazard.swift | `v & 1 == 0` (2) | full |
| SATB candidate (`satbPushIfCandidate`) | Marking/SATB.swift | full | full |
| weak keep-alive (`weakReadBarrier`) | Marking/SATB.swift | `isObject` | unchanged |
| young deletion record | YoungCollection/Mutator.swift | full | unchanged |
| marker trace (`markRef`, `markIfCandidate`) | Marking/Marker.swift | full (2) | unchanged |
| final mark, weak slots, ephemerons | Marking/FinalMark.swift | `classFormat` + full | unchanged |
| marking verifier | Marking/MarkingVerifier.swift | `isObject` | unchanged |
| scavenge (`Scavenger.evacuate`, roots, weak nil'ing) | Nursery/Scavenge.swift | full, `isObject` (4) | unchanged |
| nursery verifier | Nursery/NurseryVerifier.swift | `isObject` | unchanged |
| young collector (`Collector.evacuate`, rounds, verifier) | YoungCollection/Collect.swift, Rounds.swift, YoungVerifier.swift | full (3) | unchanged |
| relocator walk, frame pins | Relocation/Relocator.swift | full (2) | unchanged |
| full collection mark, ephemerons | ObjectMemory/Collector.swift | `isObject` (4) | unchanged |
| become forward | ObjectMemory/Become.swift | `isObject` | unchanged |
| heap verifier (`isValidReferenceOrInteger`, `verifyMarks`) | ObjectMemory/Verifier.swift | `isSmallInteger` then reference | `isImmediate` then `isValidImmediate`, else reference |
| load and store asserts | ObjectMemory/ObjectMemory.swift | `isSmallInteger ||` used | `isValidImmediate ||` used |
| snapshot loader | ObjectMemory/Snapshot.swift | the heap verifier | unchanged (through it) |
| image loader | Loader/ImageFile.swift | | the heap verifier, then `isA` on references |
| a send's class (`classIndexOf`) | Interpreter/Send.swift | `rcv & 1 != 0 ? SmallInteger : header` | SmallInteger, header if `& 0xF == 0`, else SmallFloat or Character |
| `Machine.classIndex(of:)` | Interpreter/InterpreterState.swift | `isSmallInteger ? : header` | `classIndexOf` |
| slot checks (`hasSlot`, `canStore`, `isReadOnlySlot`) | Interpreter/Dispatch.swift, Special.swift | full | full |
| `isReadOnly` | ObjectModel/ReadOnly.swift | | immediates are read-only |
| VM host roots, spawn | Workers/VM.swift | `isObject` | unchanged |

The six sites that tested `raw & 1` were all insertion barriers: with a
SmallFloat or Character stored they would have loaded the "header" of a
nonexistent entry. `immediatesAreNotReferencesInAnyCollector` stores 2000
SmallFloats, Characters, boxed Floats and SmallIntegers into an Array and
runs it through the scavenge, a young collection (local and offloaded),
a marking cycle with relocation of every live block, module 1's collection
and compaction, with every verifier on, checking every slot after each.
With one barrier site put back to `v & 1 == 0` by hand the run traps
(below, "Broken variants run by hand").

## Classes, metaclasses and formats (ADR 0009 section 6)

### The format word (`ClassFormat`, ObjectMemory/Generations.swift)

| bits | field |
|---|---|
| 0..15 | named slots |
| 16 | weak (module 4) |
| 17 | ephemeron (module 4) |
| 18..20 | kind: 0 pointers fixed, 1 pointers variable, 2 bytes, 3 16-bit words, 4 32-bit words, 5 64-bit words |
| 21 | sealed |
| 22 | behaviors: the instances are classes or metaclasses |

Weak classes are variable, ephemerons fixed with a key, the non-pointer
kinds have no named slots (`isValid`). The header still says only pointers
or bytes and the count (bytes for every non-pointer kind); `admits(isBytes:
count:)` says whether a header fits the class. `basicNew:` reads the kind
(fixed classes take no indexed slots; word kinds allocate `n x element`
bytes). kasm's `class` directive takes `fixed | variable | bytes | words16
| words32 | words64 | weak | ephemeron` and `meta=<n>` (class-side
instance variables); the default stays `variable`, module 2's behaviour.
Snapshot version 3 carries the wider word (versions 1 and 2 are refused).

**Sealed** replaces module 2's static `Image.isStructural`: CompiledMethod,
MethodDictionary, Process, Semaphore, BlockClosure, Context, Metaclass,
Behavior, ClassDescription, Class, and every metaclass. No primitive reads,
writes, creates, copies or exchanges an instance, and no method of the
class touches an instance variable; the one exception is a metaclass's
methods, which may name the class-side instance variables (slots from
`ClassLayout.size` on).

### Classic metaclasses

Every class is the sole instance of its metaclass: a class object's header
names its metaclass's index, a metaclass object's names `Metaclass`.
`Foo class superclass` is `Foo superclass class`; `Object class
superclass` is `Class`, whose chain is `ClassDescription`, `Behavior`,
`Object`. A metaclass object is the class layout plus `thisClass`. The
well-known classes are indices 1 to 26 and their metaclasses 27 to 52;
every loaded class takes two consecutive indices (class, metaclass), from
53. kasm's `method Foo class bar` is a method of Foo's metaclass.

| index | class | format |
|--:|---|---|
| 1 | SmallInteger | fixed 0 |
| 2 to 4 | UndefinedObject, True, False | fixed 0 |
| 5 | Class | fixed 5, sealed |
| 6 | CompiledMethod | fixed 10, sealed |
| 7, 8 | Array, ByteArray | variable 0, bytes |
| 9 | Symbol (a String) | bytes |
| 10 | MethodDictionary | variable, sealed |
| 11, 12 | Object, Message | fixed 0, fixed 2 |
| 13, 14 | Process, Semaphore | fixed, sealed |
| 15, 16 | SmallFloat (a Float), Character | fixed 0 |
| 17 | Float | bytes (8) |
| 18, 19 | LargePositiveInteger, LargeNegativeInteger (its subclass) | bytes |
| 20 | String | bytes |
| 21 | BlockClosure | variable 3, sealed |
| 22 | Context | variable 7, sealed |
| 23 | Metaclass | fixed 6, sealed, behaviors |
| 24, 25 | Behavior, ClassDescription | fixed 5, sealed |
| 26 | Pragma | fixed 3 |

## Bytecode set v1 (ADR 0009 section 10)

Opcodes 0 to 26 are module 2's v0 encoding unchanged; v1 appends 23:

| # | mnemonic | operands | effect | out of line? |
|--:|---|---|---|---|
| 27 | `div` (`/`) | | 2 -> 1 | the tier |
| 28 | `int_div` (`//`) | | 2 -> 1 | the tier |
| 29 | `mod` (`\\`) | | 2 -> 1 | the tier |
| 30 | `ne` (`~=`) | | 2 -> 1 | SmallIntegers inline |
| 31 | `not_identical` (`~~`) | | 2 -> 1 | inline, no send |
| 32 | `at` | | 2 -> 1 | Array inline, else the tier |
| 33 | `at_put` | | 3 -> 1 | the tier |
| 34 | `size` | | 1 -> 1 | Array inline, else the tier |
| 35 | `class_of` (`class`) | | 1 -> 1 | inline, no send |
| 36 to 38 | `value`, `value1`, `value2` | | n+1 -> 1 | the tier (closure activation) |
| 39, 40 | `is_nil`, `not_nil` | | 1 -> 1 | inline, no send |
| 41 | `send_super` | literal, argc | argc+1 -> 1 | yes |
| 42 | `push_closure` | literal (a block method), copied | copied -> 1 | yes (allocates) |
| 43 | `push_new_array` | n | 0 -> 1 | yes (allocates) |
| 44 | `push_tv_slot` | slot, temp | 0 -> 1 | inline |
| 45 | `store_tv_slot` | slot, temp | 1 -> 0, transient +3 | inline |
| 46 | `push_this_context` | | 0 -> 1 | inline when materialized |
| 47 | `block_return` | | 1 -> 0, ends | inline |
| 48 | `nonlocal_return` | | 1 -> 0, ends, transient +2 | yes |
| 49 | `ext` | high byte | prefix | yes, the whole instruction |

`store_ivar`'s transient depth is +3 too. The dispatch loop is one switch,
one case per opcode, one jump table (`just arc-check`).

**Special sends.** The fast path is inline only where it is a handful of
instructions (SmallInteger arithmetic and comparison as in module 2, `ne`,
`at:` and `size` on Arrays); everything else goes to `specialSend`, one
out-of-line call, which first tries the **tier** (SmallInteger overflow
into a LargeInteger, exact `/`, floor `//` and `\\`, any mix of SmallFloat,
boxed Float and SmallInteger for the arithmetic and comparisons, `at:`,
`at:put:` and `size` on Arrays and ByteArrays with the read-only and
barrier rules, closure activation for `value`, `value:`, `value:value:`),
then sends the selector, which leaves the stack as a plain send does.
`==`, `~~`, `class`, `isNil` and `notNil` are answered inline for every
receiver and never sent (a deviation: ADR 0009 lists `class`, `isNil` and
`notNil` with a fallback).

**The extension prefix.** `ext hi` before an extensible instruction makes
its first operand `hi << 8 | operand` (literals, temps, slots, the vector
slot, `push_new_array`'s size). The assembler emits it when an operand does
not fit a byte; it is not written in kasm. The loop runs the prefixed
instruction out of line (`extendedInstruction`). Literals go to 4095 (the
literal Array is one block).

**The verifier** (`Loader/BytecodeVerifier.swift`) is one function used by
the kasm assembler on what it encoded and by the image loader and the
method-install primitive on methods in the heap. It decodes every byte
into an instruction (`ext` only before an extensible opcode), checks
operands (temps, literals, slots against the class, a send's literal a
Symbol of its arity, a closure's literal a block method with that many
copied values, jumps onto instruction starts), the kind of return
(`return_top`/`return_self` in methods, `block_return`/`nonlocal_return`
in blocks, `nonlocal_return` only in a block with a home), and traces the
stack depth over every path with the transient words counted, answering
`maxStack`.

## Frames, closures and Contexts (ADR 0009 sections 3 and 4)

### The frame

Module 3's frame, unchanged in size; the context word now has a meaning,
and a block activation has a layout of its own:

```
method activation                       block activation (closure C)
fp[0]          receiver                 fp[0]            C's receiver (the home's self)
fp[1..argc]    arguments                fp[1..argc]      arguments
fp[1+argc..]   temps                    fp[1+argc..]     C's copied values, then temps
                                        hdr[-1]          C itself (not addressable by push_temp)
hdr[0]         method                   hdr[0]           the block method
hdr[1]         caller pc                ...
hdr[2]         caller fp
hdr[3]         caller hdr
hdr[4]         context word: nil, a Context, or a SmallInteger return marker
hdr[5..]       operand stack
```

A block method's `temps` field counts copied values, temps and the
closure word, so module 2's activation check and every frame walk work
unchanged; `fp` of any frame is `hdr - 1 - argc - temps` from its method.

### Closures and temp vectors

`BlockClosure`: block method, receiver, home (a Context, or nil), copied
values. `push_closure` (out of line, allocating) pops the copied values;
a block that returns non-locally, itself or through a block it makes
(`needsHome`, computed by the assembler and checked by the verifier), gets
its home: the current frame's Context materialized now in a method, the
enclosing closure's home in a block. A temp written after capture lives in
a temp vector: `push_new_array n` makes it, `push_tv_slot` and
`store_tv_slot` reach it through the temp that holds it (the store has the
barrier, the post-store check and the read-only check; the slot is checked
at run time, since a temp can hold anything). Closure activation
(`activateClosure`, inline into its out-of-line callers) puts the frame
together as above; `value`, `value:`, `value:value:` reach it from the
special send's tier with no lookup, and primitives 80 to 84 from ordinary
sends.

### Contexts

`Context`: frame (the header index while live, nil once detached), process,
method, receiver, closure, pc (once detached), marker; indexed: the
arguments and temps, copied at detachment. `push_this_context` and the
Context primitives materialize a frame's Context on demand into `hdr[4]`
(allocating; `Machine.materialize`). A Context is **live** when its frame
index names a header on the current Process's stack whose context word is
that Context (`liveFrame`): every primitive checks it, so no stale index
is ever followed, and a Context of another Process answers as dead in 8a
(walking a stack another worker may be running is not done).

A frame disappears in four ways, and each detaches its Context (frame nil,
temps copied, last pc kept, sender nil: Smalltalk-80's dead context):
returning (`doReturn` tests the context word against nil, one load and one
compare per return, and returns out of line otherwise), being cut by a
non-local return or `terminateTo:`, and its Process ending with an error
or a termination request (`detachAllContexts`). A Process terminated while
parked, from another Process, keeps its Contexts' indices, but they can
never be live again (their Process is not running), and `isDead` answers
true for a Context whose Process has terminated.

### Return markers

A frame the VM itself sends can carry a SmallInteger in its context word
(kept in the Context's `marker` slot if one is materialized): **discard**
(the frame was sent by a store bytecode that found its object read-only:
the answer is dropped, as the store popped its value) and **cascade** (sent
by a non-local return that could not proceed: the answer is returned from
the block as well). These sends always activate the method's body, never a
primitive answering in place, which would leave the marker unapplied.

### Non-local return and unwinding (ADR 0009 section 5)

`nonlocal_return` (out of line): the home is the block frame's closure's
home Context. If it is not live on this stack, the closure is sent
`cannotReturn:` with the value (cascade). Else the frames between the
block's caller and the home are walked for an **unwind mark** (the method
flag kasm writes as `unwind`, for `ensure:` and `ifCurtailed:`). None: the
frames above the home are cut (Contexts detached) and the home returns the
value, all in the VM. One: the home Context is sent `aboutToReturn: value
through: firstUnwindContext` (cascade) and the kernel unwinds in Smalltalk,
Smalltalk-80's way: `resume:through:` runs each pending unwind block
(`tempAt: 2` its complete flag, `tempAt: 1` the block) after
`thisContext terminateTo:` the unwind context, then terminates to the
target and answers the value. `objectmodel.kasm` has this protocol in
kasm (`ensure:`, `aboutToReturn:through:`, `resume:through:`, `return:`).

`terminateTo:` (primitive 108) cuts every frame between the running frame R
(whose Context is the receiver) and the target's frame U: their Contexts
are detached, R's words move down to where U's callee began (one
`memmove`), R takes that frame's links, so U is R's caller and R's return
answers U's send; R's Context gets its new index and R's marker is
dropped. Frame links are indices, so nothing else changes.

**Handler marks** (`handler`, for `on:do:`) are found by
`findNextHandlerContextStarting` (110) walking from a Context to the
bottom; the signal runs the handler block on top of the signaling stack, so
`resume:` is a return from `signal`'s frame and `return:` one from
`on:do:`'s, both through the same unwinding. The test kernel's `Exc
signal`, `return:`, `resume:` show the protocol; ANSI's full
`Exception` is 8b's.

### Frame pins (module 6)

The one walk the frame pins go through (`forEachRunningFrameWord`) visits
the running frame's words from receiver to sp, which include the context
word (`hdr[4]`) and a block's closure word (`hdr[-1]`).
`contextMaterializationKeepsTheFramePin` materializes a running frame's
Context, promotes it, runs a cycle that relocates every live block: the
Context is frame-pinned and does not move; with the walk skipping the
context word (test switch `pinWalkSkipsContext`) it moves.

## Sends (ADR 0009 section 11)

- **super**: a method's `methodClass` slot (its block methods' too) names
  the class it was compiled in; `send_super` looks up from that class's
  superclass through the same lookup cache, keyed by the superclass's
  index (a line keyed so answers what a receiver of that class would
  get). `superLooksUpFromTheMethodsClass` has C inherit B's method that
  sends super: with the lookup from the receiver's class's superclass (test
  switch) it recurses into a stack overflow.
- **perform:** (86 to 89) and **valueWithArguments:** (84) are activation
  primitives: they rewrite the stack and send (or activate) from
  `primitiveSend` with no further primitive. The arity is the found
  method's, or the Symbol's spelling when nothing understands it, so a
  Symbol that is not a selector of that arity fails the primitive.
- **respondsTo:** (90) is a lookup.
- **Installation** (97 `addSelector:withMethod:`, 98 `removeSelector:`):
  the method must have been compiled for the receiver (its `methodClass`)
  and pass the bytecode verifier against the receiver's shape; the new
  method dictionary is built and stored in a stop. Every worker flushes its
  lookup cache when it sees the stop's epoch (module 3) before it runs
  again, and the installing worker flushes its own after the stop, so the
  install is ordered after every flush. No primitive yet makes a
  CompiledMethod from bytes (8b's compiler needs one; the verifier it would
  call is `verifyHeapMethod`).

## Numbers (ADR 0009 sections 2 and 7)

LargePositiveInteger and LargeNegativeInteger are byte objects holding the
magnitude little-endian with no leading zero byte, and never a value that
fits a SmallInteger (**normalized**). Primitives 40 to 59 take any mix of
SmallInteger and LargeInteger (`+ - * / // \\ quo: rem: < > <= >= = ~=
bitAnd: bitOr: bitXor: bitShift: negated asFloat`), with Smalltalk's
infinite two's complement for the bit operations and floor semantics for
`//` and `\\`; `/` answers only exact quotients (Fraction is the
kernel's). The SmallInteger path is in-line Swift; anything large goes
through `BigInt` (32-bit limbs, Swift arrays) out of line (`largeArith`).
Floats: 60 to 69 (arithmetic and comparison, a SmallInteger argument
coerced), 70 to 74 (`truncated`, `fractionPart`, `exponent`,
`timesTwoPower:`, `sqrt`); results are SmallFloats when they fit and boxed
`Float`s (8 bytes) otherwise (`boxFloat`, out of line). Division by zero
fails (ZeroDivide is the kernel's). Characters: 76 `value`, 77 `Character
value:` / `asCharacter`.

`largeIntegerArithmeticAgainstInt128` checks 3000 random pairs around and
beyond the SmallInteger range through every operation against Swift's
`Int128`; `largeIntegerResultsAreNormalized` has `(2^62 + 5) - 10 ==
(2^62 - 5)` false with normalization off (test switch).

## Strings and Symbols (ADR 0009 section 8)

A String is a byte object of valid UTF-8; a Symbol is a String in the
symbol table. Strings stay valid from creation: they are made by
validation (130, refusing invalid bytes) or repair (131, U+FFFD per
ill-formed sequence, as Swift's `String(decoding:)`), concatenation (123),
copying a boundary-aligned range (127), literals, and interning, and there
is **no `at:put:` on a String or a Symbol**: primitive 2 refuses them.
`WriteStream`'s buffer is a ByteArray: `encode: aCharacter at: offset`
(128) writes the scalar's UTF-8 and answers its byte count (failing when
it does not fit); `asStringValidating` turns the filled buffer into a
String.

Positions are 1-based byte offsets valid only at scalar boundaries:
`scalarAt:` (124) decodes the scalar starting there and fails inside one
or past the end, `scalarSizeAt:` (136) its byte count, `isBoundary:` (125)
answers whether an offset (the end included) starts a scalar,
`copyFrom:to:` checks both ends, `indexOfSubstring:startingAt:` (134)
searches bytes from a boundary. `scalarCount` (126) counts. `compare:`
(120) is byte order, which for UTF-8 is scalar order; `sameBytesAs:` (121)
and `hash` (122, FNV-1a folded to a SmallInteger) are over the bytes, the
same for a String and the Symbol with its bytes. `byteAt:` and `byteSize`
(132, 133) are the `utf8` view's constant-time access. Canonical
equivalence waits for normalization (8b's String doc says so where `=` is
defined).

Interning (129 `asSymbol`, 135 `Symbol lookup:`): the symbol table is an
Array of 1024 buckets, each nil or an Array of Symbols filled from slot 0
(about four million symbols before a bucket exceeds a block). A lookup
hashes the bytes and compares in place; a new Symbol (old, pinned, read-
only) is inserted with the world stopped, looking up again inside the stop,
so two workers never intern the same bytes twice. The image and the
loader intern through the same table: Symbols are no longer host-side
names, so an image restored from a snapshot needs no host table. The table
is strong in 8a; ADR 0009's weak set is the kernel's.

These primitives read and write the heap in place, with no Swift arrays on
their paths (`just arc-check` checks `stringPrimitive` and
`Machine.intern`); repairing invalid input and making a new Symbol are out
of line.

### Where the index-free protocol made the VM side awkward

Evidence for and against the choice, as kernel.md asks:

- The WriteStream needs one more primitive than an indexed string would
  (`encode:at:` into a ByteArray, then a validated copy), and a copy at
  `contents`. With `at:put:` refused on Strings, a String cannot be its
  own buffer.
- `copyFrom:to:` in byte offsets has to check both ends; an inclusive end
  (Smalltalk's) is the last byte of a scalar, so the check is on `stop + 1`.
- Search answers byte offsets, which are only meaningful to code that
  keeps working in byte offsets: fine for streams, odd for a programmer
  who expects "the 3rd character".
- Nothing in the VM needed a scalar index; the collectors, the interner
  and the loader only ever see bytes.

## Read-only (ADR 0009 section 9)

Header bit 50. Checked by `store_ivar` and `store_tv_slot` (the slot check
already loads the header; the read-only bit widens its mask: no extra
instruction), `at:put:` (and the special send's tier), `instVarAt:put:`,
`replaceFrom:to:with:startingAt:`, `globalAt:put:`, a detached Context's
`tempAt:put:`, `encode:at:`, `become:` (either side) and `reshape` (any
instance). A refused bytecode store sends `attemptToModify: object at:
index value: value` to the object (1-based index) with the discard marker;
a refused primitive records the store and `primitiveSend` sends the same
message in place of its answer (the frame's one reserved word covers the
extra argument). Immediates answer `isReadOnly` true. Method literals,
their literal Arrays and bytecodes, Symbols and pragmas are read-only.
Primitives 93 `setReadOnly:` (answering the previous state) and 94
`isReadOnly`; sealed classes refuse 93. The bit is set and cleared with
one atomic or/and on the header word, not a plain store: module 7's young
collector compare-and-swaps young headers while mutators run, and now
retries keeping bit 50 when the word changed under it
(`readOnlyFlipsRaceNoYoungCollection`, local and offloaded, 300 000 flips
during collections, no claim failure). The collectors never read the bit.

## Stack growth (kernel.md question 4)

A Process's stack is one malloc'ed segment (module 3's `stackWords`, 8192
by default). When an activation does not fit, `stackOverflow` grows it:
a segment large enough (doubling) is allocated, words `[0, sp]` copied,
the record's `base` and `end` updated under the scheduler lock, the old
segment freed, the registers recomputed from the saved ones, and the
activation done again. Nothing in the stack changes: frame links, saved pcs
and Context frame numbers are indices and offsets. Only the running
Process grows, and no other thread reads a running Process's stack (stops
park its worker, young collectors scan parked stacks), so freeing the old
segment at once is safe. Past `maxStackWords` (1 Mi words, 8 MiB) a frame
that does not fit is module 3's stack overflow. Module 2's standalone
interpreter keeps its fixed stack. `stackGrowthPreservesFrameLinks` runs a
recursion 3000 deep from a 256-word stack (6 or more growths): the bottom
frame's Context, materialized before the first growth, is still live at
the deepest frame, and a non-local return from there finds it.

## Pragmas

kasm's `pragma <selector> <literal>...` before a method's first
instruction makes a `Pragma` (selector, arguments Array, method) literal
at the end of the literal frame; the loader checks the selector's arity
against the argument count and that the arguments are literals, and makes
the Pragma and its Array read-only. No index (8b). `theLoaderAcceptsTheV1
Shapes` shows the shape.

## kasm v1

```
class <Name> <Superclass> <instSize> [fixed|variable|bytes|words16|words32|words64|weak|ephemeron] [meta=<n>]
method <Class> [class] <selector> temps=<n> [prim=<k>] [unwind] [handler]
  pragma <selector> <literal>...
  <label>:
  <op> [operands]
block <name> args=<n> copied=<n> temps=<n>
  ...
end
```

A method's blocks follow its body; `push_closure <name> <copied>` names
one, each block is made by exactly one `push_closure` and reachable from
the method (no cycles). Literals: integers of any size, floats (`1.5`,
`1e10`), characters (`$a`, `$U+1F600`), strings (`'it''s'`, spaces
allowed), `#selector`, `@Class`, nil, true, false. The opcode for `class`
is `class_of` (a line `class` inside a method is ambiguous with the
directive).

## The image format

`Loader/ImageFile.swift`: magic `KAJOIMG`, version 1, the special-objects
Array (a root: nil, true, false, globals, symbol table, the selectors the
VM uses, `doesNotUnderstand:`), the method table, then module 1's
snapshot. `Image.saveImage` collects first, then snapshots;
`Image.load(image:)` loads the snapshot with module 1's checks, then
`verifyImage`, then builds the Image from the heap (well-known objects from
the special objects, class names and method tables from the classes and
their dictionaries). All or nothing: on any failure the object memory is
destroyed and the error thrown.

The rules (`verifyImage`): every registered class's format valid; the
special objects of their classes and sizes; the symbol table's buckets
holding valid-UTF-8 Symbols in the bucket their hash names, no two alike;
the selectors Array holding the special-send and VM selectors; every class
object a behavior naming its index, as large as its metaclass's format
says, its metaclass a sealed behaviors format whose Metaclass instance
names it back, its superclass chain acyclic and ending in nil, its method
dictionary of Symbols and Methods compiled for it; the well-known classes
with their names and formats; every object admitted by its class's format;
no Process (8a cannot save one), no live Context, every closure the shape
of its block method; the method table equal to the set of CompiledMethods
in the heap, each passing `verifyHeapMethod` for its class (the bytecode
verifier with `maxStack` at least the traced depth, header values in range,
selector arity, block shape, literals' block methods verified as blocks of
the same class, nesting at most 64) and pinned for good with its bytecodes
and literal Array, which are read-only.

`theImageLoaderRejects` builds 21 corrupt images (each rule, plus the file
header) and every one is refused for its own reason (the messages are
printed by the test); `mutatedImagesLoadCleanOrAreRejected` flips bits in
300 copies; `FuzzEntry.image` is the fuzz entry, reached by `fuzz-snapshot`
for inputs with the image magic.

The fuzzer found two crashes, both one bit from a valid input and both now
regression fixtures in `Fixtures/fuzz/snapshot/` (`fuzzFoundInputsNeverTrap`):
`crash-wellknown-name.img`, an image whose well-known class name was a
Character that the loader read as an object (every slot read in the image
loader is now guarded by the holder's size and kind), and
`crash-marker-offset.img`, a snapshot whose entry 52 carried a young
deferred-free header and a body offset with bit 48 set; the heap verifier
skips a deferred free's body (it may be reused), so the offset went
unchecked and the marker read it. The snapshot loader now refuses any young
or deferred-free entry (a snapshot follows a promote-all, so neither can
be in one). The first crash came from the fallback mutation driver, the
second from the first coverage-guided libFuzzer run of the target (3.8
million inputs in 600 s), which the fallback had not reached in the same
time.

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS 27,
swift.org Swift 6.4.2, 2026-11-03 16:40 to 16:44 (load average 3.3 to 6.0
1-minute, the agent session the busiest other process). Module 7's
`kajo` from a worktree at 689fa20 and this module's at 99ddb9e, both built
`-c release` with `-align-all-nofallthru-blocks=5 -align-loops=32`; five
runs interleaved (`bench.sh`), `--slice-ms 0`; median (min to max) ms.

### The v0 kernels against module 7

| kernel | workers | module 7 ms | module 8a ms | 8a / 7 | checksums |
|---|--:|--:|--:|--:|---|
| fib | 1 | 1683.2 (1682 to 1691) | 1694.1 (1694 to 1722) | **1.006** | 24682992 |
| fib | 8 | 232.6 (216 to 246) | 228.6 (224 to 242) | **0.983** | 24682992 |
| arith | 1 | 2591.2 (2577 to 2594) | 2550.7 (2544 to 2555) | **0.984** | 372800000 |
| arith | 8 | 353.5 (343 to 359) | 352.0 (344 to 354) | **0.996** | 372800000 |
| sends | 1 | 2605.4 (2604 to 2680) | 2586.8 (2583 to 2591) | **0.993** | 1066666666666668 |
| sends | 8 | 359.7 (346 to 366) | 350.0 (332 to 351) | **0.973** | 133333335000001 |
| ivars | 1 | 2069.9 (2068 to 2078) | 1976.5 (1974 to 1979) | **0.955** | 36383626 |
| ivars | 8 | 286.5 (266 to 291) | 260.2 (253 to 278) | **0.908** | 71714128 |
| storeheavy | 1 | 2258.7 (2240 to 2267) | 2409.9 (2399 to 2417) | **1.067** | 512000 |
| storeheavy | 8 | 291.8 (291 to 306) | 321.7 (312 to 341) | **1.102** | 512000 |
| alloc | 1 | 2949.3 (2930 to 2971) | 2939.8 (2935 to 2962) | **0.997** | 41950911 |
| alloc | 8 | 455.7 (440 to 511) | 466.3 (460 to 495) | **1.023** | 42008248 |

- fib, arith, sends and alloc are within noise of module 7 (0.97 to 1.02);
  ivars is faster (0.91 to 0.96: placement, as module 7 measured for its
  own changes).
- **storeheavy is not within noise: 1.067 on one worker, 1.10 on eight.**
  It is the read-only check: an aligned build of this module with the
  store bytecode's mask back to the bytes bit alone ran storeheavy at
  2251.8, 2246.5, 2264.5 ms against module 7's 2254.4, 2254.3, 2263.4 in
  the same session (three runs each, interleaved). storeheavy does eight
  SmallInteger `store_ivar`s per loop iteration and nothing else, so
  the second header test (bit 50 next to bit 47; two `tbz`/`tst` forms and
  a contiguous four-bit mask measured the same) costs about two cycles a
  store there. ivars, which stores and loads, does not show it.
- **The first build of this module was 5 to 23 percent slower on every
  kernel** (fib 1.05, arith 1.12, sends 1.15 to 1.21, storeheavy 1.21 to
  1.23 at five runs). The cause was register allocation in the larger
  dispatch loop, found in the disassembly: the loop kept fp and hdr as one
  vector register pair and unpacked both at every dispatch (two
  instructions per bytecode), and spilled the entry-table base, the heap
  base and the safepoint flag pointer (three loads more per `store_ivar`).
  Three changes brought it back: the v1 fast paths that need extra live
  values run out of line from their own cases (arith 1.12 to 1.04), `Regs`
  stores fp and hdr apart so they are not loaded as a vector pair (to 0.98
  to 1.00 on everything but storeheavy), and the store's mask (above).
  Routing every v1 opcode through the `default` case or the `nil` case
  instead was worse (an extra compare per dispatch, or the table base
  recomputed per dispatch).
- `interpret` is 1056 instructions (module 7: 794), one indirect branch,
  one jump table of 50 entries (`just arc-check`).

### The new kernels (module 8a only)

| kernel | workers | ms | checksum |
|---|--:|--:|---|
| closures | 1 | 3707.4 (3704 to 3726) | 210210000 |
| closures | 8 | 494.8 (482 to 500) | 209214000 |
| floats | 1 | 3214.0 (3197 to 3242) | 7499750000 |
| floats | 8 | 423.7 (412 to 440) | 33747999993 |

closures: 60 000 repetitions of 1000 closure activations through a real
`from:to:do:` loop (each a `value:` special send into the tier, a temp
vector read and write, `\\` as a full send), plus a non-local return from
two frames up with its home Context materialized and the frames cut:
about 62 ns per element. floats: 30 million steps of `x * 0.999 + (i *
0.25)` and a comparison, every one through the out-of-line tier (a
SmallInteger and a SmallFloat never meet in the inline fast path),
about 107 ns per step, no boxing (`floatsBoxed` 0). Both scale 7.5x on
eight workers. The 8-worker checksums are different programs (each
worker does its share), as module 3 noted for sends and alloc. Neither
kernel has an earlier module to compare with; putting the SmallFloat path
inline would make floats faster and is a measured trade-off against the
loop's register budget, not built.

## Changes to modules 1 to 7

Module 1 (`ObjectMemory/`):

- `Oop`: SmallFloat and Character (`isSmallFloat`, `isCharacter`,
  `isImmediate`, `isValidImmediate`, `init(smallFloat:)`,
  `init(character:)`, `SmallFloat.encode`/`decode`); `isReserved` now means
  a spare tag or a Character that is not a scalar.
- `Header`: bit 50 read-only (`readOnlyBit`, `isReadOnly`); the reserved
  bits are 46 and 51. The reserved-bit corruption tests use bit 51.
- `ClassFormat`: kind, sealed, behaviors, `isValid`, `admits`; module 4's
  initializer keeps its meaning (variable unless ephemeron).
- Snapshot version 3 (the wider format word; formats checked with
  `isValid`); versions 1 and 2 are refused, the fuzz seed regenerated.
- The snapshot loader refuses a used entry whose header is young or a
  deferred free, next to its frame-pin check (the fuzzer's second crash,
  under "The image format").
- The heap verifier and the load/store asserts accept valid immediates and
  refuse the spare tags.
- `reshape` refuses read-only instances (`ReshapeError.readOnlyInstance`)
  and keeps the format word's named-slot count in step.
- `destroyContext` returns the context's private free list to the pool (it
  was in no list until the next sweep; the free-list verifier before a
  snapshot reported it once interpreters ran on an image that is then
  saved).
- `TestSwitches` gained module 8's switches (below).

Module 2 (`Interpreter/`, `Loader/`):

- `Opcodes.swift`: bytecode set v1 (above); `specialIndex`,
  `specialArgc`, `transientDepth`, `isExtensible`, `decodeInstruction`.
  The `class` opcode's mnemonic is `class_of`.
- `ObjectModel.swift`: well-known classes 1 to 26 and their metaclasses,
  `firstUserClass` 53, the class, metaclass, method, closure, Context and
  Pragma layouts, `MethodFlags`; `Method` is named CompiledMethod and
  MethodDict MethodDictionary in the image (the test that sends
  `basicNew` to them says `@CompiledMethod`).
- `Send.swift`: `classIndexOf` (the class of any word), the return's
  context-word test and `returnSlow`, `specialSend` takes the selector
  index and argc and tries the tier first, `primitiveSend` hands the
  activation primitives over and sends `attemptToModify:at:value:` after a
  refused store, `stackOverflow` grows the stack; `Regs` stores fp and hdr
  apart.
- `Dispatch.swift`: the v1 cases; `store_ivar` checks the read-only bit
  and calls `storeRefused`; `nil`, true and false as before.
- `Stack.swift`: `Frame.emptyContext` (SmallInteger 0) is the context word
  of a plain frame (module 3 wrote nil).
- `InterpreterState`: `symbolTable`, the read-only failure record,
  `stackGrowths`, the counters below; `Machine.classIndex(of:)` covers
  immediates, `refuseReadOnly`; `become:` refuses read-only and sealed
  objects.
- `Primitives.swift`: `at:put:` refuses Strings, Symbols and read-only
  receivers, `globalAt:put:` read-only globals; `basicNew:` reads the
  class format and refuses the immediate classes; 40 to 79 and 90 to 136
  go to `objectModelPrimitive`; `Image.isStructural` is
  `ObjectMemory.isSealed`.
- `KasmParser.swift`, `Assembler.swift`: v1 kasm (formats, `meta=`,
  `method Foo class`, `unwind`, `handler`, `pragma`, `block`, the new
  literals); the assembler encodes with `ext` and runs
  `BytecodeVerifier.swift`.
- `Image.swift`: boot with metaclasses and the special-objects Array;
  Symbols interned in the heap table (no host-side symbol table); names
  read from the heap; method literals, literal Arrays and bytecodes
  read-only; `init(memory:limits:restoring:)` for images.
- `LoadError.swift`: `maxLiterals` 4095.
- `FuzzEntry`: `image`, `snapshotOrImage`, `imageSeed`.

Module 3 (`Workers/`, `Processes/`):

- `VMConfig.maxStackWords`; counter `stackGrowths`; `growStack`.
- `runSlice` detaches a Process's Contexts when it ends by an error or a
  termination request.
- `Worker.make` gives the interpreter the symbol table.

Module 4 (`Nursery/`):

- The insertion barrier's "is it a reference" test is the full pattern
  (SmallIntegers tested first).
- `BarrierSite`: `storeTempVector`, `instVarAtPut`, `contextSlot`,
  `closureSlot`, `installMethod`, `symbolTable`; scenarios for the first
  two (caught when switched off), the reasons the rest cannot be caught
  in `barrierSitesCaught`'s comment.

Module 5 (`Marking/`): `storeWithBarriers`'s insertion barrier tests the
full pattern.

Module 6 (`Relocation/`): `storeConflict` and the array copy (its broken
variant too) test the full pattern; the array copy refuses a read-only
receiver; `forEachRunningFrameWord` documents and covers the context and
closure words, with the test switch that skips the former.

Module 7 (`YoungCollection/`): the collector's claim retries its
compare-and-swap keeping bit 50 when the read-only primitive changed the
header under it (any other change is still counted as a claim failure);
the round log's append is out of line (`logRound`), which kept ARC out of
`runRound` with the swift.org 6.4.2 toolchain, where module 7's own build
also showed it.

Scripts: `check-hot-path-arc.sh` covers module 8's paths and counts the
jump table by its table loads when the compiler hoists the table's address
(the relocation names a section label, not `lJTI`: module 7's build failed
the check with this toolchain too); `golden.sh` runs closures and floats.

Tests of modules 1 to 7 changed where the model changed on purpose:
encoding (the spare tags), verifier and snapshot corruptions (spare tag
`0x108`, reserved bit 51), the opcode table (50 opcodes), the boot test
(metaclasses, formats, superclasses), class indices in the loader tests
(53 on, two per class), `maxStack` with the store's transient words, the
assembler rejections (`push_ivar 4095`, malformed literals), the
overflow tests (a LargeInteger, no send), the literal limit test, the
`Runtime` and `Harness` helpers (test switches, a post-load hook), the
random programs (closures and non-local returns; the relocation tally).

## Deviations

From the brief (kernel.md) and ADR 0009, each with its reason:

- **`class`, `isNil`, `notNil`, `~~` are answered inline for every
  receiver** with no fallback send (the ADR lists `class`, `isNil` and
  `notNil` among the special sends with a full-send fallback). Open
  question for the owner.
- **Most v1 fast paths run out of line** (one call from their own case):
  inline, the larger loop's register allocation spilled the heap and table
  bases and unpacked fp and hdr from a vector register at every dispatch,
  costing the v0 kernels 5 to 23 percent (Measurements). The loop keeps
  one case per opcode and one jump table.
- **`push_new_array`** is an opcode the ADR does not list: temp vectors
  have to be made.
- **The `class` opcode's kasm name is `class_of`**: a line `class` inside
  a method is ambiguous with the directive.
- **kasm classes default to `variable`** (v0 behaviour), not Smalltalk's
  fixed; `fixed` is explicit.
- **`attemptToModify:at:value:` is sent to the object with the object as
  its first argument**, the selector read literally; open question.
- **Read-only is set with an atomic or/and**, not "one relaxed store":
  module 7's young collector compare-and-swaps young headers concurrently.
  AGENTS.md's "mutators must not set bits in a live header" was written
  for non-atomic writes; this one is atomic and the only concurrent writer
  retries.
- **Contexts of other Processes are dead to the primitives** (and to
  non-local return, which sends `cannotReturn:`); reading a running
  Process's frames from another worker is not built.
- **A Process cannot be saved in an image**; the image loader refuses
  one, and refuses live Contexts.
- **The symbol table is strong** (ADR: a weak set, the kernel's).
- **Sends the VM makes with a return marker activate the method's body**
  even when it has a primitive.
- **The dispatch loop loads nil from the interpreter state at `push_nil`**
  instead of holding it in a register (a register for nil cost the store
  path its table base).
- **Opcode numbering**: v0's 27 kept, v1 appended (the brief left
  numbering to the table).

## Tests

297 test functions in the suite (module 7: 250), 47 of them new in
`Tests/KajoVMTests/ObjectModel/`:

| file | tests |
|---|---|
| ClosureTests | closures with copied values, temp vectors, nested blocks and the value sends, a wrong-arity value, non-local return straight to the home, **through an ensure block (with the broken variant `skipUnwindMarks`)**, cannotReturn:, thisContext materialized, live, detached with its temps, on:do: with return:, resume:, an outer handler with an ensure block between |
| SendTests | **super through the method class (broken variant: from the receiver's class)**, perform: and its arities, respondsTo:, perform with the wrong arity, class-side methods and class instance variables, the special sends' fast paths and fallbacks, the ext prefix past 255 literals, method installation (another class's method refused, removal) |
| NumberTests | SmallFloat against Double (200 000 values), Characters, float arithmetic on the special sends (boxing and back), **LargeIntegers against Int128**, **normalization (broken variant)**, LargeInteger literals |
| StringTests | scalars at boundaries only, **a position inside a scalar fails (broken variant `noBoundaryCheck`)**, copy, concatenate, count, search, equality, hashing and interning, encoding into a buffer and validation, invalid bytes refused unless repaired, no at:put: on a String |
| ReadOnlyTests | **a store bytecode into a read-only object sends attemptToModify:at:value: and drops its answer**, the store primitives refuse (at:put:, the special at:put:, instVarAt:put:, replaceFrom:to:with:startingAt:), literals read-only, become: and reshape refuse |
| ObjectModelVMTests | **immediates through every collector (stw, local, offload)**, **the Context frame pin (broken variant `pinWalkSkipsContext`)**, **stack growth preserving frame links** and the overflow past the maximum, **read-only flips during young collections**, **a removed method gone from another worker's cache** |
| LoaderV1Tests | **41 rejections of malformed v1 constructs**, the shapes the loader builds (blocks, pragmas, formats, metaclasses) |
| ImageFileTests | an image round trip that runs and loads more kasm, **21 rejected corruptions**, 300 mutated images, **the two inputs the snapshot fuzzer crashed on, refused** |
| SeedTests | every kasm fuzz seed loads |

Changed elsewhere: `aBarrierSiteSwitchedOff` (two new caught sites),
`randomProgramsAgreeWithTheirModel` (closures and non-local returns),
`scaledKernelsMatchTheirModels` and `goldenKernelChecksums` (closures,
floats).

## Broken variants run by hand

Rules whose broken variant traps, would cost the hot path a switch, or
needs code removed, run by hand on 2026-11-03 (debug builds, each restored
afterwards); the in-suite switches are listed under Tests.

| rule | broken variant | test | result |
|---|---|---|---|
| immediates are not references in the barriers | `storeWithBarrier`'s test back to `v.raw & 1 == 0` | `immediatesAreNotReferencesInAnyCollector` | the test process dies: "exited with unexpected signal code 11" (the barrier loads the "header" of a SmallFloat's nonexistent entry) |
| the read-only check in `store_ivar` | `canStore` without bit 50 | `aStoreIntoAReadOnlyObjectSendsAttemptToModify` | fails: the store happens, `readOnlyRefusals` is 0, the run's answer differs |
| detachment on return | `doReturn` without the context-word test | `thisContextIsMaterializedOnDemandAndDetachedOnReturn` | fails: the returned frame's Context stays "live" (its index now names a later frame) and the run does not answer 5 + 77 |
| installation in a stop (every worker flushes its cache) | the install primitive edits the dictionary without the stop | `aRemovedMethodIsGoneFromEveryWorkersCache` | fails after 230 s: the spinner on worker 1 never sees the removal ("rt.result(spinner) → -1") |
| stack growth updates the record | `growStack` leaves the record's `base` and `end` | `stackGrowthPreservesFrameLinks` | the test process aborts: "exited with unexpected signal code 6" (termination frees the old segment a second time) |
| the image loader verifies every method | `verifyImage` skips `verifyHeapMethod` | `theImageLoaderRejects` | 5 of 21 corruptions load: badOpcode, jumpIntoAnOperand, maxStackTooSmall, literalNotASelector, ivarOutsideTheClass |

## Unsafe surface

Lines with `unsafe` (comments excluded), clean build with no warning
(`.build/clean-check`, 0 warnings):

| file | lines |
|---|--:|
| ObjectModel/Frames.swift | 166 |
| Interpreter/Special.swift | 136 |
| ObjectModel/Closures.swift | 50 |
| Processes/StackGrowth.swift | 17 |
| ObjectModel/Strings.swift | 9 |
| ObjectModel/ObjectModelPrimitives.swift | 5 |
| ObjectModel/ReadOnly.swift | 3 |
| ObjectModel/Numbers.swift | 2 |
| ObjectModel/Symbols.swift, Loader/BytecodeVerifier.swift, Loader/ImageFile.swift | 0 |
| **new files** | **388** |

Changed: Dispatch 84 to 115, Send 136 to 159, InterpreterState 42 to 47,
Allocation 62 to 63, Rounds 172 to 173, Collect 321 to 320. The whole
`Sources/KajoVM` has 4234 such lines. Nearly all are the same kinds as
module 2's: the stack, register and state pointers, frame words read and
written by index, the stack segment's malloc, copy and free, and the
header atomic of the read-only bit. The verifier, the image loader, the
assembler, the parser, the number and String code over the heap, and the
symbol table are safe code; they reach the heap only through module 1's
safe loads and stores.

## Hot-path check

`just arc-check` on the final code: 137 functions, zero
`swift_retain`/`swift_release` (module 1 to 7's list plus module 8's:
`v1Instruction`, `superSend`, `extendedInstruction`,
`activationPrimitive`, `primitiveFailure`, `spreadArray`, `isSelectorOf`,
`returnSlow`, `nonLocalReturn`, `attemptToModifyFromStore`,
`attemptToModifyFromPrimitive`, `pushThisContext`, `markedSend`,
`Machine.materialize`, `detach`, `detachFrames`, `framePC`, `liveFrame`,
`contextPrimitive`, `detachAllContexts`, `pushClosure`, `pushNewArray`,
`Machine.integerArith`, `floatArith`, `boxFloat`, `stringPrimitive`,
`Machine.intern`, `growStack`, `storeRefused`). `interpret`: 1056
instructions, one indirect branch, one jump table (the table's address is
hoisted into a register before the loop, and this toolchain names it by a
section label: the script now counts the table loads; module 7's build
failed the old check with swift.org 6.4.2 as well). The post-store
sequence of `store_ivar` is module 6's. With this toolchain module 7's
`runRound` had ARC 2 (the round log's array append inlined); the append is
out of line now. The LargeInteger arithmetic (`largeArith`, Swift arrays),
repairing invalid UTF-8, making a Symbol, and installing a method are out of
line and not on the list.

## Not done

- 8b: the bootstrap compiler, `kernel/`, the image build, SUnit, the
  NDJSON event stream, the pragma index.
- A primitive that makes a CompiledMethod from bytes and literals (8b's
  Smalltalk compiler needs it; `verifyHeapMethod` is what it would call).
- Reading the frames of another Process (debugger), freezing a Process
  into Contexts, saving Processes in an image, resuming from Contexts.
- Unicode normalization and grapheme segmentation (canonical equivalence
  of Strings), case mapping beyond ASCII (both the kernel's, later).
- A weak symbol table.
- `ifCurtailed:` in the test kernel (the unwind mark is the same flag).
- LargeInteger division is binary long division (quadratic in bits):
  correct, slow for very large numbers; Knuth's algorithm D is a later
  optimisation behind the primitive.
- Stack segment chaining (the brief's choice: copying only).
- A barrier-site scenario for a Context detached into an old Context.

## Gates

On the final commit (`45c18bc`, after the fuzzer's second crash was fixed),
the whole sequence once more, on the Mac mini (M2 Pro) with the swift.org
6.4.2 toolchain, every output in a file:

| gate | result |
|---|---|
| `swift test` | 297 passed, 92 s |
| under load (12 busy loops) | 297 passed, 115 s |
| ThreadSanitizer | 297 passed, 0 reports, 375 s |
| ThreadSanitizer under load | 297 passed, 0 reports, 560 s |
| `just ios-check` | 0 warnings |
| `just arc-check` | OK: no retain or release, `interpret` 1056 instructions, one jump table |
| `just golden` | 9 of 9 checksums |
| `just test-release` | 297 passed |
| `just model-check` | 28 + 15 passed |
| `just soak` | passed |
| `just fuzz kasm 600` | libFuzzer, 2.46 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer, 6.98 million runs, no crash |
| clean build | 0 warnings |

The run before it, on `6390ff2`, was the same except for the two findings
that made `45c18bc`: the hog test's CPU bound under the sanitizer (24 ms
against 20 in the full suite) and the snapshot fuzzer's crash.

## Commands

```zsh
S=<scratch>; git worktree add $S/m7 689fa20
A2=(-Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5 -Xswiftc -Xllvm -Xswiftc -align-loops=32)
(cd $S/m7 && swift build -c release --product kajo --scratch-path .build/bench-a2 $A2)
swift build -c release --product kajo --scratch-path .build/bench $A2
zsh bench.sh $S/m7/.build/bench-a2/release/kajo .build/bench/release/kajo bench.txt 5
python3 agg.py bench.txt
swift test
for i in $(seq 12); do gtimeout 1500 yes > /dev/null & done; swift test; pkill -x yes
swift test --sanitize=thread --scratch-path .build/tsan-check > tsan.txt 2>&1
for i in $(seq 12); do gtimeout 1500 yes > /dev/null & done
swift test --sanitize=thread --scratch-path .build/tsan-check > tsan-load.txt 2>&1; pkill -x yes
just ios-check; just arc-check; just golden; just test-release; just model-check; just soak
just fuzz kasm 600; just fuzz snapshot 600
rm -rf .build/clean-check && swift build --scratch-path .build/clean-check 2>&1 | grep -c warning:
```

The scripts:

```zsh
# bench.sh <m7 kajo> <m8 kajo> <out> [runs]: for run, kernel in fib arith
#   sends ivars storeheavy alloc, workers 1 and 8, m7 then m8:
#   kajo run prelude lib <kernel> --workers W --slice-ms 0
#   then closures and floats on m8 only (module 7 cannot load them).
# agg.py: the median, minimum and maximum ms per kernel, workers and binary.
```
