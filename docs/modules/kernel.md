# Module 8: object model v1 in the VM, the kernel, the compiler, the image

Status: 8a (the VM side) built 2026-11-03, described in
`docs/modules/object-model.md`; 8b (the Smalltalk side) built 2026-11-03,
described in `docs/modules/kernel-image.md` (the bootstrap compiler, the
kernel, the image build, SUnit and the event stream, the compiler in
Smalltalk, the weak symbol table and `modificationForbiddenAt:value:`);
saved Processes in images are 8c, next. The six questions of the proposal were answered by the owner the
same day and the answers are folded in below. 8a's deviations from this
brief are listed in object-model.md; the String section below holds as
written for the VM side.

Decisions it implements: ADR 0009 in full (sections 2 to 12, with section 8
rewritten for a single String and section 9's bit moved to 50), ADR 0002's
`kernel/` directory, and the loader rule left open by module 2: an image
format that verifies every method before any of it runs.

## Two halves

**8a, the VM side.** Everything ADR 0009 asks of `Sources/KajoVM`:

- Bytecode set v1 in the opcode table (`Opcodes.swift`): extension prefix,
  inlined control flow, special sends with full-send fallback, `push_closure`,
  temp-vector slots, `push_this_context`, `send_super`, `block_return`,
  `nonlocal_return`. The kasm assembler and the stack-depth tracer follow
  the table; the dispatch loop stays one jump table (arc-check).
- Immediates: SmallFloat (`..10`, 9-bit exponent) and Character (`0100`, a
  Unicode scalar); module 1's verifier and loaders accept them; arithmetic
  primitives take the inline fast path and box out of line. Every place
  that tests `raw & 1` for "not a reference" (barriers, the post-store
  check's callers, the collectors' slot scans) tests the full immediate
  pattern instead; the inventory of those sites is in the module doc.
- Closures, temp vectors, home Contexts; Context materialization on demand
  into the frame slot module 3 reserved (`hdr[4]`), detachment on return;
  non-local return and unwinding with `ensure:` marks; `on:do:` handler
  marks and resumable signaling on the signaling stack. Frame pins (module
  6) keep working for materialized frames: the pin walk goes through the
  one function module 6 left for it.
- Classic metaclasses and the class format word (module 4 has weak and
  ephemeron; add pointers fixed and variable, bytes, 16-, 32-, 64-bit words,
  named-slot count).
- LargePositiveInteger and LargeNegativeInteger primitives with
  normalization; boxed Float for what SmallFloat cannot hold.
- One UTF-8 `String` and interned `Symbol` (ADR 0009 section 8 as amended;
  the design is under "String" below); primitives for byte comparison,
  hashing, concatenation, scalar decoding at a byte offset, boundary
  checks, scalar encoding into a stream buffer, interning.
- Read-only bit 50 and its checks in every store path; the failure sends
  `modificationForbiddenAt:value:` (8a sent `attemptToModify:at:value:`;
  changed in 8b). Method literals are read-only in the image.
- `perform:` family, `respondsTo:`, `super` through the method's defining
  class, cache flush ordering on method install.
- Stack growth by copying (question 4): a Process's stack is one segment;
  when a frame does not fit, a segment twice the size is allocated and the
  stack copied. Module 2's frame links are offsets, so nothing in the stack
  changes; the interpreter's cached pointers are recomputed. Segment
  chaining is not built.
- The image format: module 1's snapshot plus a method table that the loader
  verifies with the stack-depth tracer and the class-format rules before
  the image runs. Loading an image is all-or-nothing. The fuzz target
  `fuzz-snapshot` grows to cover it.

**8b, the Smalltalk side.** `kernel/` sources, a bootstrap compiler in
Swift, the image build, the test harness, and the compiler in Smalltalk:

- The bootstrap compiler (`Sources/KajoCompiler/`, Swift) parses Smalltalk
  method syntax and emits bytecode set v1 plus literals, with the same
  checks the kasm loader makes. It builds the first image from `kernel/`
  and **stays as the oracle** (question 2): the Smalltalk compiler's output
  for every kernel method must equal it, or the difference is explained in
  a test. It is also what `kajo` uses to compile a method sent over the
  development protocol before the image has a compiler, and the syntax
  fuzzing target.
- `kernel/` is one file per class in the **Tonel format** (question 1):
  a class definition header (name, superclass, instance variables, class
  variables, category, format) followed by methods in plain Smalltalk
  syntax with their protocol, metaclass methods marked as such. The parser
  is small enough that both compilers read it. Nothing is copied from
  another Smalltalk's sources; the protocol names follow Smalltalk-80 and
  ANSI where they exist (question 3), so that Smalltalk programmers are at
  home, with the one exception of String.
- The class list: Object, Behavior, ClassDescription, Class, Metaclass;
  UndefinedObject, Boolean, True, False; Magnitude, Number, Integer,
  SmallInteger, LargePositiveInteger, LargeNegativeInteger, Fraction,
  Float, SmallFloat; Character; String, Symbol; Collection,
  SequenceableCollection, ArrayedCollection, Array, ByteArray,
  OrderedCollection, Interval, HashedCollection, Set, IdentitySet,
  Dictionary, IdentityDictionary, Association; BlockClosure, Context,
  CompiledMethod, Message, MessageNotUnderstood; Exception, Error,
  ZeroDivide, SubscriptOutOfBounds, Warning, Notification, UnhandledError,
  `ensure:`, `ifCurtailed:`, `on:do:`, `signal`, `retry`, `resume`,
  `return:`, `pass`, `outer`; Process, ProcessorScheduler, Semaphore, Mutex,
  Monitor, SharedQueue, Delay; WeakArray, Ephemeron, the finalization
  Process; ReadStream, WriteStream, ReadWriteStream on collections and a
  `WriteStream` that builds Strings; Transcript as a stream the headless
  CLI emits as events; a compiler (Scanner, Parser, Semantic analysis,
  BytecodeGenerator) in Smalltalk; TestCase, TestResult, TestSuite in the
  SUnit style with the kernel's own tests.
- The image build is a test (`kajo build-image` then `kajo test` runs the
  kernel's tests), and snapshot, load, verify is a round trip in CI.

## String (decided here, open to change behind the module)

The owner wants one String type and Swift or Rust as the inspiration
(question 3). The Smalltalk-80 string protocol is an integer-indexed array
of characters, which UTF-8 cannot offer in constant time, so String is the
one kernel class whose protocol does not follow prior art:

- **Representation**: a byte object of UTF-8, validated once when created
  from bytes (a primitive; invalid input fails or is repaired with U+FFFD,
  the caller chooses). Equality and hash are over the bytes (canonical
  equivalence waits for normalization, listed under Not done; the module
  doc says so where `=` is defined). Literals are read-only.
- **Immutability**: there is no `at:put:` on String. Strings are built by
  `,` and by `WriteStream` over a growable byte buffer whose `contents`
  answers a String; mutation of a scalar in place would change the byte
  length, as Rust's `String` has no index assignment for the same reason.
- **Elements and iteration**: `do:`, `collect:`, `select:`, `detect:`,
  `reverseDo:`, `includes:` and friends work over Unicode scalars and yield
  Characters (ADR 0009 section 2). A `graphemes` view is a later library
  once the Unicode tables exist; until then the module doc says that a
  Character is a scalar, not a user-perceived character, as Rust's `char`.
- **Positions**: byte offsets, 1-based as everything in Smalltalk, valid
  only at scalar boundaries (Rust slicing). `copyFrom:to:`, `indexOf:`,
  `indexOfSubstring:startingAt:`, `readStream` positions and the
  `WriteStream` position all speak in these offsets; a position inside a
  scalar fails with an error, never answers a broken string.
- **Size**: `size` is not defined on String, because neither byte count
  nor scalar count is the obvious answer; `isEmpty` and `notEmpty` are,
  `utf8 size` answers the bytes in constant time, `scalarCount` counts.
- **Views**: `utf8` answers a read-only, constant-time indexed ByteArray
  view (`at:`, `size`, `do:`, `copyFrom:to:`) sharing the bytes;
  `scalars` is the String itself; `graphemes` later.
- **Protocol spelling**: Smalltalk selectors for what Smalltalk-80 and
  Swift agree on (`,`, `asUppercase`, `asLowercase`, `trimmed`,
  `beginsWith:`, `endsWith:`, `includesSubstring:`, `replaceAll:with:`
  answering a new String, `splitOn:`, `lines`, `asSymbol`, `asInteger`,
  `printString`, `displayString`); Swift's semantics where they differ
  (comparison is by scalar value, case mapping is full Unicode later and
  ASCII in v1, both documented).
- **Interop**: a Swift `String` crosses the shell boundary as a memcpy of
  its UTF-8 either way, which is the reason for the whole choice.

The module doc records every place the index-free protocol made kernel
code awkward, as evidence for or against the choice.

## Pragmas (decided here, open to change behind the module)

Pragmas (`<keyword: literal ...>` at the start of a method, Smalltalk-80's
syntax for `<primitive: n>`) are the kernel's one metadata mechanism, in
Pharo's style: a method carries its own registration, and a consumer asks
the image for every method tagged with a pragma instead of keeping a list.

- The compiler parses pragmas into `Pragma` objects (selector, arguments,
  method) stored as literals of the `CompiledMethod`; `method pragmas`,
  `pragmaAt:`, `Pragma allNamed:in:` and `allNamed:` are the protocol.
- **A pragma index** in the image, keyed by pragma selector, updated by
  method installation and removal, so a query is a dictionary lookup and
  not a scan of every method; the index is rebuilt by the image loader.
- **Unconsumed pragmas warn.** A consumer declares the pragma selectors it
  understands (itself a class-side pragma, `<consumesPragmas: #(...)>`);
  the compiler warns on a pragma no consumer declares, as a compile
  warning the headless CLI emits as an event and the development UI shows,
  never silently as Pharo does (a typo in `<expectedFailure>` is a test
  that quietly passes). Compilation still succeeds.
- Class-level tags are the Tonel header's category and tags, and behavior
  tags are class-side pragma methods; there is no third mechanism.
- Initial uses in 8b: `<primitive: n>` with its failure code path; main
  thread affinity (ADR 0004: a method tagged for the UI thread, which the
  scheduler checks in checked builds and the UI shows); the development
  protocol (methods and event vocabularies exposed to the remote UI and
  to agents); test tags (`<slow>`, `<device>`, `<expectedFailure>`) that
  `kajo test --tag` selects by and the NDJSON events carry. Type or
  protocol annotations, if ever wanted, ride in the same slot as an
  optional tool (Strongtalk's way), never as a VM feature.

## Test harness and the event protocol (question 5)

- `TestCase`, `TestResult`, `TestSuite` in the SUnit style in the kernel;
  `kajo test [image] [--filter pattern] [--tag tag]` runs them headless.
- The CLI's machine-readable output is a **stream of NDJSON events** on
  stdout, one JSON object per line, timestamped with the time each
  happened (not when it was written: AGENTS.md), versioned with `"v": 1`.
  This stream is the first form of the **core event protocol** the shells
  (module 9) and the remote development UI consume later; the test events
  are its first vocabulary and nothing in it is test-specific by design.
  Event kinds in v1: `run.started`, `test.started`, `test.passed`,
  `test.failed` (with the message and a frame list), `test.errored`,
  `transcript` (Transcript output, with the Process), `gc` (a collection's
  counters, from the existing reports), `run.finished` (totals and time).
- `--junit <path>` writes **JUnit XML** for CI, derived from the same
  events at the end of the run; the human-readable summary on stderr is
  derived from them too, so there is one source of truth.

## Scope (question 6, the owner's judgement delegated)

In the first image: Fraction (the integer `/` answers one when the division
is not exact, as in every Smalltalk; it is pure Smalltalk and keeps the
number tower honest), the collections and streams above, exceptions,
processes, weak and ephemeron, the compiler, SUnit.

Out of the first image: ScaledDecimal, Date and Time, Random, regular
expressions, Unicode normalization and grapheme segmentation, text
formatting and interpolation, Bag, SortedCollection, LinkedList.

When date and time come, the owner wants an API in the style of JavaScript
Temporal (immutable `Instant`, `PlainDate`, `PlainTime`, `PlainDateTime`,
`ZonedDateTime`, `Duration`, `TimeZone`, explicit calendars) and no
mutable Date-style class; that becomes its own ADR when the module is
briefed.

## Order

8a first, gated like every module (tests, load, ThreadSanitizer alone and
under load, ios-check, arc-check, golden, fuzz); the kasm assembler gains the
v1 opcodes so the randomized programs and the fuzzers cover closures and
unwinding before any Smalltalk runs. Then 8b, with the bootstrap compiler's
tests first (parse, compile and run each kernel class's methods as they are
written), the kernel class by class with its tests, the image build, the
test harness and the event stream, and the compiler in Smalltalk last,
compared against the bootstrap.

## Answers recorded (2026-11-03)

1. Source format: Tonel, one file per class.
2. The Swift bootstrap compiler stays as the oracle.
3. Prior-art names and methods, except String: one String type, UTF-8,
   Swift or Rust as inspiration.
4. Stack growth by copying.
5. JUnit XML for CI; NDJSON streaming as the core event protocol.
6. Scope at my judgement; a Temporal-style date and time API later, no
   legacy Date-style API.

8a's open questions, answered the same evening (ADR 0009 "Built (8a)"):
`class`, `isNil`, `notNil` stay inline and non-overridable; the read-only
failure is `modificationForbiddenAt:value:`; the symbol table is weak (built
in 8b); the read-only check's `storeheavy` cost is accepted; images hold
Processes (module 8c, after 8b).
