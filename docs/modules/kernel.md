# Module 8: object model v1 in the VM, the kernel, the compiler, the image

Status: proposal (2026-11-02), awaiting the owner. This is the first module
where the language itself is designed, so nothing here is launched until the
questions at the end are answered. Becomes a brief, then the description.

Decisions it implements: ADR 0009 in full (sections 2 to 12), ADR 0002's
`kernel/` directory, and the loader rule left open by module 2: an image
format that verifies every method before any of it runs.

## Two halves

**8a, the VM side.** Everything ADR 0009 asks of `Sources/KajoVM`:

- Bytecode set v1 in the opcode table (`Opcodes.swift`): extension prefix,
  inlined control flow, special sends with full-send fallback, `push_closure`,
  temp-vector slots, `push_this_context`, `send_super`, `block_return`,
  `nonlocal_return`. The kasm assembler and the stack-depth tracer follow
  the table; the dispatch loop stays one jump table (arc-check).
- Immediates: SmallFloat (`..10`, 9-bit exponent) and Character (`0100`);
  module 1's verifier and loaders accept them; arithmetic primitives take
  the inline fast path and box out of line.
- Closures, temp vectors, home Contexts; Context materialization on demand
  into the frame slot module 3 reserved (`hdr[4]`), detachment on return;
  non-local return and unwinding with `ensure:` marks; `on:do:` handler
  marks and resumable signaling on the signaling stack.
- Classic metaclasses and the class format word (module 4 has weak and
  ephemeron; add pointers fixed and variable, bytes, 16-, 32-, 64-bit words,
  named-slot count).
- LargePositiveInteger and LargeNegativeInteger primitives with
  normalization; boxed Float for what SmallFloat cannot hold.
- UTF-8 `String`, `AsciiString`, interned `Symbol`; primitives for
  comparison, hashing, scalar indexing, concatenation.
- Read-only bit 48 and its checks in every store path; the failure sends
  `attemptToModify:at:value:`.
- `perform:` family, `respondsTo:`, `super` through the method's defining
  class, cache flush ordering on method install.
- Stack growth or segment chaining for Processes (ADR 0004's open item),
  since kernel code recurses deeper than kasm kernels did.
- The image format: module 1's snapshot plus a method table that the loader
  verifies with the stack-depth tracer and the class-format rules before
  the image runs. Loading an image is all-or-nothing. The fuzz target
  `fuzz-snapshot` grows to cover it.

**8b, the Smalltalk side.** `kernel/` sources, a bootstrap compiler in
Swift, the image build, and the compiler in Smalltalk:

- The bootstrap compiler (`Sources/KajoCompiler/`, Swift) parses Smalltalk
  method syntax and emits bytecode set v1 plus literals, with the same
  checks the kasm loader makes. It builds the first image from `kernel/`
  and remains as the oracle: the Smalltalk compiler's output for every
  kernel method must equal it, or the difference is explained.
- `kernel/` is the kernel class library in a text format one file per
  class (see questions): Object, Behavior, ClassDescription, Class,
  Metaclass; UndefinedObject, Boolean, True, False; Magnitude, Number,
  Integer, SmallInteger, LargePositiveInteger, LargeNegativeInteger, Float,
  SmallFloat, Fraction later; Character; String, AsciiString, Symbol;
  Collection, SequenceableCollection, ArrayedCollection, Array, ByteArray,
  OrderedCollection, Interval, HashedCollection, Set, IdentitySet,
  Dictionary, IdentityDictionary, Association; BlockClosure, Context,
  CompiledMethod, Message, MessageNotUnderstood; Exception, Error,
  ZeroDivide, SubscriptOutOfBounds, Warning, Notification, UnhandledError,
  `ensure:`, `ifCurtailed:`, `on:do:`, `signal`, `retry`, `resume`,
  `return:`, `pass`, `outer`; Process, ProcessorScheduler, Semaphore, Mutex,
  Monitor, SharedQueue, Delay; WeakArray, Ephemeron, the finalization
  Process; ReadStream, WriteStream, ReadWriteStream on collections;
  Transcript as a stream the headless CLI prints; a compiler (Scanner,
  Parser, Semantic analysis, BytecodeGenerator) in Smalltalk; TestCase,
  TestResult, TestSuite in the SUnit style with the kernel's own tests.
- The image build is a test (`kajo build-image` then `kajo test` runs the
  kernel's tests), and snapshot, load, verify is a round trip in CI.
- Nothing is copied from another Smalltalk's sources (AGENTS.md: references
  are for inspiration, this is greenfield); the protocol names follow
  Smalltalk-80 and ANSI where they exist so that Smalltalk programmers are
  at home.

## Order

8a first, gated like every module (tests, load, ThreadSanitizer, ios-check,
arc-check, fuzz); the kasm assembler gains the v1 opcodes so the randomized
programs and the fuzzers cover closures and unwinding before any Smalltalk
runs. Then 8b, with the bootstrap compiler's tests first (parse, compile and
run each kernel class's methods as they are written), the kernel class by
class with its tests, the image build, and the compiler in Smalltalk last,
compared against the bootstrap.

## Questions for the owner

1. **Source format for `kernel/`.** One file per class with methods in
   plain Smalltalk syntax and a small header (class name, superclass,
   format, instance variables, category), diff-friendly and readable in any
   editor; the Tonel format is the nearest existing one. Or a custom Kajo
   format. Recommendation: one file per class, Tonel-like, with the parser
   small enough that both the Swift and the Smalltalk compiler read it.
2. **The bootstrap compiler in Swift stays as the oracle**, as the
   stop-the-world collector does. Alternative: throw it away once the
   Smalltalk compiler compiles itself. Recommendation: keep it; it is also
   what `kajo` uses to compile a method sent over the development protocol
   before the image has a compiler, and it is the fuzzing target for syntax.
3. **ANSI Smalltalk protocol names** as the baseline for the kernel's
   public protocol, with Kajo additions where the design differs
   (Processes that truly run in parallel, read-only objects, ephemeron
   ownership of native resources). Or a fresh naming scheme. Recommendation:
   ANSI names where they exist.
4. **Stack growth**: segment chaining (a Process's stack is a list of
   segments, a frame never spans two) versus copying growth (allocate a
   bigger segment and copy, which the offset-based frame links of module 2
   allow for free). Recommendation: copying growth, because frame links are
   offsets and nothing in a stack needs fixing; the cost is a copy at each
   doubling.
5. **The first user-visible test harness**: SUnit-style `TestCase` in the
   kernel and `kajo test` in the CLI. Any preference on names and output
   format (TAP, JUnit XML for CI)?
6. **Scope cut for v1**: Fraction, ScaledDecimal, Date and Time, Random,
   regular expressions, Unicode normalization, and a text formatting
   library are left out of the first image. Anything that must be in?

Until these are answered, 8a can be briefed on its own: it depends only on
ADR 0009 as accepted, and nothing in it is affected by the answers except
stack growth (question 4).
