# Review: kernel at d78afcc

## Summary
I read every file of `Sources/KajoCompiler/` (Syntax, Compiler, Tonel, KernelBuilder, FuzzSyntax: about 2,500 lines) and `Sources/fuzz-syntax/main.swift` whole, and from `kernel/` the compiler in Smalltalk (Scanner, Parser, Compiler, CompilerScope, BytecodeGenerator), DevSession, DevProtocol, Debugger, most of DebugStop, TonelReader, TonelWriter, ClassBuilder, Exception, Context's unwinding, BlockClosure's handlers, Mutex, Semaphore, Transcript, UnhandledError, HashedCollection, Dictionary, Pragma's index, and the relevant parts of Smalltalk, String, Integer, Number, Float, Fraction, Interval and OrderedCollection (about 5,500 of the 18,370 kernel lines). I checked the make primitive's and the redefine primitive's checks in `Sources/KajoVM` only where a kernel path depends on them. Nothing was built or run. I found three high-severity bugs a program can hit with no race involved. `Transcript show:` deadlocks the image's Transcript when an object's `displayString` fails. `on:do:` uses the class `ExceptionSet` as its retry marker, so a protected block that answers that class retries forever, and so does a protocol request that inspects such an object. `Exception>>outer` leaves the exception's handler set to the outer one, so the inner handler then returns from the wrong `on:do:`. A fourth high finding is a class of concurrency bugs: request Processes run in parallel and change the kernel's shared registries without a lock. One of them, `Pragma rebuildIndex`, has the exact "published empty, then filled" shape fixed last night. The rest are medium: compiler disagreements that let a live-accepted method break the image rebuild, Tonel round-trip breakage, stack overflows that leave a request with no reply, and numeric hash inconsistency. I did not read tools/, the UI wrappers, Json, the stream classes, most kernel tests, or the Swift tests beyond their names.

## Findings (ranked, most severe first)

### F1. `Transcript show:` runs the argument's `displayString` (and `showLine:` its `nextPutAll:`) inside a non-reentrant Semaphore, so an error or a log line in there deadlocks every Transcript writer
- Severity: high   Confidence: confirmed
- Where: `kernel/System/Transcript.class.st` `show:` (the `lock critical: [stream nextPutAll: (... anObject displayString)]`), `showLine:` (`stream nextPutAll: aString` inside the lock with no type check); `initialize` makes `lock` a `Semaphore forMutualExclusion` (not reentrant).
- Invariant: "shared by every Process under a lock" (the class comment); a lock's critical section must not run user code that can block on the same lock or end the Process without releasing it.
- Path that breaks it: `Transcript show: anObject` where `anObject printOn:` signals an Error (an ordinary bug while developing), or `Transcript showLine: 42`. The Error is unhandled, so `UnhandledError>>defaultAction` runs. That path is either `reportAndEnd` (`Transcript showLine:`) or `Debugger stop:` → `parked:` (`Transcript showLine:`). Either way the same Process waits on the Semaphore it holds. It never ends and never releases the lock. Every later Transcript write in any Process blocks forever. That includes the protocol Process's own error logging (`DevProtocol serve` → `Transcript show:`), `Debugger parked:` for every later stop, and `Unwinding` reports. In a batch host (`kajo test`) the run hangs. A `printOn:` that itself logs to the Transcript deadlocks the same way with no error at all.
- Neighbours that have it right: `Transcript print:` and `display:` compute the String outside the lock, then call `show:` with a String; `cr` and `flush` only touch the stream inside.
- Test that would fail today: TranscriptTest: a class whose `printOn:` sends `self error:`; fork `[Transcript show: thatObject]`; then from the test Process `Transcript showLine: 'x'` must return within a bound (it never does). A second case: `showLine: 42` in a forked Process, then the same bound.
- Fix sketch: compute the text before taking the lock (`text := anObject isString ifTrue: [...] ifFalse: [anObject displayString]`) and check `isString` in `showLine:` before the lock. Better still, make `lock` a Mutex so a nested write by the same Process cannot deadlock.

### F2. `on:do:`'s retry marker is the class `ExceptionSet`: any protected block or handler that answers that class retries forever
- Severity: high   Confidence: confirmed
- Where: `kernel/Methods/BlockClosure.class.st` `on:do:` (`== Exception retryMarker`), `kernel/Exceptions/Exception.class.st` `class >> retryMarker` (answers `ExceptionSet`). Reached from `kernel/Development/DevSession.class.st` `evaluate:receiver:` (`[self objectAt: receiver] on: Error do:`) and `inspect:` (`[obj slotAt: i] on: Error do:`, `[obj basicAt: k] on: Error do:`), and from every kernel or user `on:do:`.
- Invariant: `on:do:` answers its protected block's value (or the handler's); only `Exception>>retry` restarts it.
- Path that breaks it: a client sends `evaluate` with source `ExceptionSet` and gets a handle h. Then `evaluate` with receiver h makes `[self objectAt: h] on: Error do: [...]` answer the class `ExceptionSet`. `on:do:` takes that as "retry" and loops forever, burning a worker, and the request never replies. `inspect` of a handle to `{ExceptionSet}` (or any object with that class in a slot) does the same through `basicAt:`/`slotAt:`. In plain code, `[Smalltalk at: #ExceptionSet] on: Error do: [:e | nil]` hangs, and so does a handler block whose last value is `ExceptionSet`.
- Neighbours that have it right: none; the marker is reachable by any program.
- Test that would fail today: ExceptionTest: `self assert: ([ExceptionSet] on: Error do: [:e | nil]) == ExceptionSet`, run in a forked Process with a bound; and `([1/0] on: ZeroDivide do: [:e | ExceptionSet]) == ExceptionSet`.
- Fix sketch: make the marker a private object no program can obtain, for example a class-side instance variable holding `Object new` that is never answered from anywhere. Better, make retry a flag in the handler frame (a fourth temp) that `privateOn:do:` checks, instead of a sentinel value.

### F3. `Exception>>outer` leaves `handlerContext` on the outer handler: afterwards `return:`, `retry`, falling off the handler and `resume:` act on the wrong `on:do:`, and the inner handler stays marked busy
- Severity: high   Confidence: confirmed
- Where: `kernel/Exceptions/Exception.class.st` `outer` (calls `searchFrom:`, whose `evaluateHandlerIn:` sets `handlerContext := aContext`, and nothing restores it), then `evaluateHandlerIn:` (`^ self return: value`), `return:`, `retry`, `resume:` (`handlerContext tempAt: 3 put: nil`).
- Invariant: ANSI `outer`: when the enclosing handler resumes, `outer` answers the value and the current handler stays the active one (stated in the method's own comment, "a resumption answers from outer").
- Path that breaks it: `[[x := (Warning signal: 'w'). x * 10] on: Warning do: [:e | e outer + 1]] on: Warning do: [:e | e resume: 1]`. The outer handler resumes, so `outer` answers 1. The inner handler finishes with 2 and runs `self return: 2`, but `handlerContext` is now the outer `on:do:` frame. The outer `on:do:` answers 2, unwinding past the inner one and skipping the rest of its protected block (`x * 10` never runs). Also, `resume:` after `outer` clears the outer frame's busy flag, not the inner one's. A second `Warning` signalled later in the same protected block then skips the inner handler and goes to the outer one. `e retry` after `e outer` retries the outer protected block.
- Neighbours that have it right: `pass` returns through `self return:` immediately, so the handler it replaced is never used again.
- Test that would fail today: ExceptionTest `testPassAndOuter` asserts only `e resume: 100` after `outer`, which `signalContext` serves correctly. Add: the expression above must answer 20; and `[(Warning signal) + (Warning signal)] on: Warning do: [:e | e outer. e resume: 1]` inside an outer `on: Warning do: [:e | e resume: 5]` must have both signals reach the inner handler (count them).
- Fix sketch: in `outer`, save `handlerContext`, call `searchFrom:`, then restore it and set the inner frame's busy flag again (temp 3 := true) before answering the value. `pass`'s and `outer`'s non-resumable branches are unchanged.

### F4. Kernel registries that concurrent request Processes write are unsynchronized: lost entries, duplicate handles, and a `Dictionary` that can fill up and loop forever in `indexFor:`
- Severity: high   Confidence: likely (the race is reasoned from the code and ADR 0009 §12; no run)
- Where: `kernel/System/Smalltalk.class.st` `noteSource:of:`, `noteCategory:of:in:`, `notePackage:of:in:`, `noteDefinition:of:`, `noteUndeclared:in:`, `forgetSourceOf:` (each also does `x isNil ifTrue: [x := IdentityDictionary new]`); `kernel/Methods/Pragma.class.st` `noteInstalled:`/`noteRemoved:` (OrderedCollections inside the index); `kernel/Development/DevSession.class.st` `handleOf:` and `inspectRelease:` (`handles`, `nextHandle`), written from request Processes and, through `frameDetail:session:`, from stopped Processes; `kernel/Development/DevProtocol.class.st` `argumentNamesOf:` (from the protocol Process in `take:` and from request Processes in `describe`); `kernel/Collections/HashedCollection.class.st` `rehashTo:` publishes `array := Array new: newSize` before refilling it.
- Invariant: ADR 0009 §12, "Kernel collections are not synchronized. Sharing between Processes goes through Semaphores, Mutexes, Monitors and queues". DevProtocol runs each request in its own Process (`forkAt: 1`), and those Processes run in parallel on workers.
- Path that breaks it: two clients (the tools and an agent), or one client pipelining requests, send `method.compile` at the same time. Both Processes run `Behavior>>compile:classified:` and write `sources` and `organizations` at once. Then:
  - A lost `tally := tally + 1` leaves the tally below the true count. `growIfNeeded` then never grows the table and it fills completely. After that, an `indexFor:` of an absent key never finds a nil slot and loops forever: every later `sourceOf:` miss hangs its Process.
  - A rehash racing an insert loses the insert (a method with no source: the debugger shows no variables, the Tonel writer fails with "has no source").
  - A reader during a rehash sees the empty new array and answers "absent" for a present key.
  - `handleOf:` can give two objects the same handle: both Processes increment `nextHandle`, and the second `at:put:` overwrites the first. One client then inspects or releases the other's object.
- Neighbours that have it right: DevProtocol's `pending` and `sessions`, Debugger's `stops` and `suspends`, View's `registry`, Delay's `pending` and Transcript all go through a lock. `rebuildClassNames` (211a6ee) builds its table in a temporary first.
- Test that would fail today: a kernel test forking 8 Processes that each `compile:` 200 distinct methods into one test class, then checks that every method has `Smalltalk sourceOf:` and that `sources`' per-class dictionary has `size` equal to the number of methods. The same for 8 Processes calling `aSession describe: Object new` 500 times each, asserting distinct handles. Run under load; it asserts the invariant, not a timing.
- Fix sketch: one Mutex beside `Smalltalk`'s registries (class-side), held by every `note*`/`forget*` and by the readers that iterate. A Mutex per DevSession for `handles`. Pragma's index under the same lock as installation. For tables that are rebuilt, publish the new table only once it is filled.

### F5. `Pragma rebuildIndex` publishes an empty index and then fills it: the shape 211a6ee fixed for class names
- Severity: medium   Confidence: confirmed (the shape); likely (the client-visible effect)
- Where: `kernel/Methods/Pragma.class.st` `rebuildIndex` (`PragmaIndex table: IdentityDictionary new.` then `noteInstalled:` for every method). Callers: `ClassBuilder class>>redefine:...` (whenever methods were recompiled), `Smalltalk initializeKernel`, and `Pragma index` when the table is nil. Readers: `Pragma allNamed:`, which `DevProtocol rebuildKinds` uses on `session.open` (`info` → `describe`), on `protocol.describe` and on every unknown kind (`selectorOf:`).
- Invariant: a table other Processes read is published only once it is whole (commit 211a6ee, `rebuildClassNames`).
- Path that breaks it: an agent redefines a class (a `class.define` that reshapes) while a client opens a session or sends a request kind not yet cached. `rebuildKinds` reads the half-built index and builds `kinds` without some `<devProtocol>` methods. `protocol.describe` and the `session.open` count then answer a partial list, and `kajo mcp` builds its tools from it. A request whose kind is missing is answered "unknown request" if the retry in `selectorOf:` also lands inside the rebuild. A concurrent `noteInstalled:` writes into the table being rebuilt.
- Neighbours that have it right: `Smalltalk rebuildClassNames`, `DevProtocol rebuildKinds` (builds `d`, then assigns).
- Test that would fail today: fork a Process that loops `Pragma rebuildIndex` 200 times. Meanwhile, in the test Process, assert 2000 times that `(Pragma allNamed: #devProtocol) size` equals the count taken before.
- Fix sketch: build the new IdentityDictionary in a temporary and assign it at the end (`table: d`), and answer it, as `rebuildClassNames` does.

### F6. Unbounded recursion in kernel code that runs on untrusted or cyclic input ends the request Process with a stack-overflow VMError and no reply
- Severity: medium   Confidence: likely (the VMError ending reasoned from `VMConfig.maxStackWords` and `Run.swift`; not run)
- Where: `kernel/Compiler/Compiler.class.st` `analyze:in:` and `gen:in:on:value:` recurse on a MessageNode's receiver, so a chain of N unary or binary sends is N nested activations. The bootstrap compiler walks chains with loops (`Compiler.chain`, the reserve-and-depth lesson); the Smalltalk one, which compiles every protocol method, does not. Also `kernel/Development/DevSession.class.st` `printOf:` → `printString` of a cyclic collection (`Collection>>printOn:` has no recursion guard and the 4000-byte cut comes after the whole String is built). `DebugStop>>frameDetail:session:` calls `describe:` from the stopped Process itself.
- Invariant: "a malformed request is a reply" (AGENTS.md, ADR 0011), and "Recursion over untrusted input is bounded against the smallest stack it runs on".
- Path that breaks it:
  - `method.compile` with a source of `foo ^ 1` followed by 200,000 copies of ` abs` (well under the 16 MiB request limit). The parser loops, but `analyze:` recurses 200,000 deep. Past `maxStackWords` (1 Mi words) the Process ends with a VMError, not a Smalltalk exception. `DevProtocol run:`'s `on: Error do:` never sees it, no reply is sent, and the `pending` entry leaks.
  - `evaluate` of `| a | a := OrderedCollection new. a add: a. a` ends the same way in `describe:`.
  - A stopped Process whose frame holds such a collection dies when a client asks for its frames. The Process being debugged is lost without unwinding.
- Neighbours that have it right: `Sources/KajoCompiler/Compiler.swift` `chain` and `SendNode.deinit`; the Parser in Smalltalk (its chains are loops).
- Test that would fail today: CompilerTest `Compiler compile: 'foo ^ 1' , (String new: 300000 withAll: ...' abs')` must answer a CompiledCode or signal CompileError (it overflows today). DevelopmentTest: `describe:` of a self-containing OrderedCollection must answer within the 4000-byte bound.
- Fix sketch: walk receiver chains with a loop in `analyze:` and `gen:`, as `Compiler.chain` does. Give `printOf:` a bounded stream that stops writing at 4000 bytes and a recursion set (Pharo's `printStringLimitedTo:`). Make `DevProtocol run:` reply when its Process ends without one (for example an ensure that calls `finishActiveWithError:`).

### F7. The two compilers disagree on identifiers: a method the live system accepts is refused when the image is rebuilt from its files
- Severity: medium   Confidence: confirmed
- Where: `kernel/Compiler/Scanner.class.st` `isLetterAt:` (any non-separator scalar above 127 starts and continues an identifier) against `Sources/KajoCompiler/Syntax.swift` `isLetter`/`identifierRun` (Unicode alphabetic to start; alphabetic, digits or numeric type to continue). The class comment says so, but nothing guards the consequence.
- Invariant: the round trip (live compile → Tonel files in `--project` → `kajo build-image`) and "An invariant the loader checks on load binds every live change" (AGENTS.md).
- Path that breaks it: `method.compile` of `× aNumber ^ self * aNumber`, or `foo | a·b | ...`, or a temp named with an emoji. The Smalltalk scanner reads `×`, `a·b` and the emoji as identifiers, so the method compiles, installs and is written to the project file. The bootstrap scanner throws "unexpected character", so the next image build from those files is refused.
- Neighbours that have it right: every other token rule matches token for token.
- Test that would fail today: CompilerTest: for a list of scalars (U+00D7, U+00B7, U+2192, U+1F600, U+00A0), assert that `Compiler compile:` accepts exactly when a Swift fixture (KernelImageTests) accepts, or simply that the kernel compiler refuses them.
- Fix sketch: give the Smalltalk scanner the bootstrap's rule. That needs a Unicode letter test the kernel lacks, so either add a primitive answering `Unicode.Scalar.properties.isAlphabetic`, or restrict both compilers to the same explicit set.

### F8. A comment containing `[` inside a method's message pattern makes the written Tonel file unreadable by both readers
- Severity: medium   Confidence: likely
- Where: `kernel/System/TonelWriter.class.st` `patternAndBodyOf:` (the pattern ends at `Scanner patternEndIn:`, which skips comments between keyword parts, so the comment stays in the pattern). `Sources/KajoCompiler/Tonel.swift` `read()` ("the pattern runs to the first [ outside a string": the code stops at the first `[` of any kind) and `kernel/System/TonelReader.class.st` `readMethodInto:` (the same).
- Invariant: byte identity of the round trip (TonelRoundTripTests; "the tool's output is the canonical form").
- Path that breaks it: `method.compile` of `at: i "index in [1, size]" put: v  ^ v`. Both compilers accept it. The writer writes `Foo >> at: i "index in [1, size]" put: v [ ... ]`. The readers take the comment's `[` as the body's opening bracket, `matchingBracket` closes at the comment's `]`, and the rest of the line is read as the next method's metadata, so the build fails. A leading comment before the pattern (`"helper [x]" foo`) does the same.
- Neighbours that have it right: `matchingBracket` skips comments and strings once it is inside a body.
- Test that would fail today: TonelTest: compile the method above into a test class, `TonelWriter sourceOf:`, read it back with `TonelReader read:`, and expect the same source.
- Fix sketch: in both readers, skip comments (and strings) while looking for the pattern's `[`. Or have the writer move a pattern's comments after the pattern.

### F9. A live redefinition can give a class a class variable that a subclass already declares (or an instance variable already uses); the image build refuses the result
- Severity: medium   Confidence: likely
- Where: `kernel/Classes/ClassBuilder.class.st` `redefine:...` (checks only duplicate instance variable names in `reshape:`). `Sources/KajoVM/ObjectModel/LiveClasses.swift` around line 541: the pool check passes `inherited` (the superclasses' pools) and empty instance variables, and its comment says "instance variable names live in the kernel, which checks them".
- Invariant: `ClassRules.namesProblem`, which `Plan` (the image build) enforces: class variables are unique along the chain and shadow no instance variable of either side, and no own instance variable shadows a visible class variable.
- Path that breaks it: class A with subclass B declaring class variable `Cache`; `class.define` A with `classVariables: 'Cache'`. Neither the kernel nor the VM compares A's new pool with B's, so it is accepted. The written files then declare `Cache` in both A and B, and `kajo build-image` refuses with "B: class variable Cache shadows A's class variable". The same happens when A gains instance variable `Foo` while A or a superclass has class variable `Foo`, or gains class variable `X` while a subclass has instance variable `X`.
- Neighbours that have it right: `newClass:` through primitive 145 (`namesProblem` with the inherited pool and the own instance variables).
- Test that would fail today: LiveClassTest: the define above must signal ClassDefinitionError; and a round trip of the resulting files through `Plan` must not throw.
- Fix sketch: in `redefine:`, run the full names rule for the class and every subclass against the new pools and shapes before calling primitive 146. Or have primitive 146 call `namesProblem` per affected class with its all-names lists.

### F10. Smalltalk's `pass` returns from the inner `on:do:` when no outer handler exists and the default action answers (a resumable exception should resume); `retryUsing:` runs its block before unwinding
- Severity: medium   Confidence: confirmed
- Where: `kernel/Exceptions/Exception.class.st` `pass` (`^ self return: (self searchFrom: handlerContext sender)`, so a `defaultAction` value is returned from `on:do:`) and `retryUsing:` (`handlerContext return: (aBlock value)`).
- Invariant: ANSI and Pharo: `pass` is "as if this handler did not exist", so an unhandled resumable exception resumes at its signal with the default action's value. `retryUsing:` replaces the protected block and runs the new block in the handler's place, under the same handler.
- Path that breaks it: `[Notification signal. #after] on: Notification do: [:e | e pass]` answers nil in Kajo, and `#after` in Pharo (the default action answers nil and resumes). The same goes for `Warning` with no outer handler. `[...] on: ZeroDivide do: [:e | e retryUsing: [1/0]]`: the retry block runs inside the busy handler, so its ZeroDivide is not caught by this handler and becomes unhandled.
- Neighbours that have it right: `outer` resumes for resumable exceptions (apart from F3).
- Test that would fail today: ExceptionTest: `self assert: ([Notification signal. #after] on: Notification do: [:e | e pass]) == #after`.
- Fix sketch: in `pass`, when `searchFrom:` reaches the default action of a resumable exception, resume at `signalContext` with its value. `retryUsing:` returns a marker telling `on:do:` to evaluate the new block as its protected block.

### F11. `Fraction` and `Float` that are `=` hash differently
- Severity: medium   Confidence: confirmed
- Where: `kernel/Numbers/Fraction.class.st` `hash` (`numerator hash bitXor: denominator hash`); `kernel/Numbers/Float.class.st` `hash` (`(self * 1048576.0) truncated hash` for a fraction part); `Fraction>>=` retries with coercion, so `(1/2) = 0.5` is true.
- Invariant: `a = b` implies `a hash = b hash` (every HashedCollection relies on it).
- Path that breaks it: `(Set with: 1/2) includes: 0.5` answers false while `(1/2) = 0.5`. A Dictionary keyed by `1/2` misses `0.5`.
- Neighbours that have it right: Integer against integral Float (`truncated hash`).
- Test that would fail today: FractionTest `self assert: (1/2) hash = 0.5 hash` (and `(3/4)` against `0.75`).
- Fix sketch: hash a Fraction through its Float value when that value is exact (or always through `asFloat hash`), as Pharo does.

### F12. Mutex and Semaphore `critical:` leak the lock if the Process is terminated between `wait` and entering `ensure:`
- Severity: medium   Confidence: likely
- Where: `kernel/Processes/Mutex.class.st` `critical:` (`semaphore wait. owner := me. ^ aBlock ensure: [...]`); `kernel/Processes/Semaphore.class.st` `critical:`.
- Invariant: a lock is released however its holder ends (Process>>terminate runs every pending unwind block).
- Path that breaks it: `process.terminate` (or `Process>>terminate`) interrupts a Process at the poll between the primitive `wait` returning and the `ensure:` activation, a send that polls. No unwind frame holds the signal yet, so the Semaphore stays taken. DevProtocol's `lock`, Debugger's `lock` and Transcript's lock then block every later user: the protocol stops serving.
- Neighbours that have it right: none in the kernel; Pharo's `critical:` wraps the wait itself (`caught` flag inside `ensure:`).
- Test that would fail today: hard to hit deterministically. A stress test forks 1000 Processes doing `m critical: []` while another terminates them at random, then asserts `m critical: [true]` returns within a bound.
- Fix sketch: `| caught | caught := false. ^ [caught := true. semaphore wait. owner := me. aBlock value] ensure: [caught ifTrue: [...signal]]`, with `caught` set by the VM's wait (or decide in the ensure block whether this Process owns the Mutex).

### F13. A client can suspend or terminate the protocol Process itself, after which the image serves nothing until relaunched
- Severity: low   Confidence: confirmed
- Where: `kernel/Development/DevSession.class.st` `processSuspend:`, `processTerminate:`; `kernel/Development/Debugger.class.st` `suspend:` (refuses only the active Process). `process.list` lists the protocol Process.
- Invariant: development-protocol.md: requests are served by the protocol Process. A stopped Process is resumed only by a command that arrives through it.
- Path that breaks it: `process.suspend` with the protocol Process's id parks it in `DebugStop>>serve`. Every later request, including the `process.proceed` that would resume it, waits for that same Process. `process.terminate` ends it outright. An agent cleaning up "waiting Processes" does this by accident.
- Neighbours that have it right: `suspend:` refuses the active Process.
- Test that would fail today: DevelopmentTest: `process.suspend` of `DevProtocol`'s Process must be an error reply.
- Fix sketch: refuse suspend and terminate (and step) of `DevProtocol`'s Process (and of the Process that runs the request) with an error reply.

### F14. The Smalltalk bytecode generator encodes operands without range checks: jump offsets wrap and counts above 255 fail with a generic Error instead of a CompileError
- Severity: low   Confidence: possible (whether a wrapped jump can verify depends on the make primitive bounding bytecode size, which I did not find)
- Where: `kernel/Compiler/BytecodeGenerator.class.st` `assembleWithExtraLiterals:` (`rel bitAnd: 255` and `(rel bitShift: -8) bitAnd: 255` for jumps; `bytes nextPut: a; nextPut: (inst at: 3)` for send argc, closure copied count and vector temp index; `nextPut: (a bitShift: -8)` for an ext prefix above 65535). Compare `Sources/KajoVM/Loader/Assembler.swift:442` ("jump too far") and the bootstrap's per-operand refusals.
- Invariant: "Every count a bytecode encodes has a refusal and a test at its limit" (AGENTS.md). `LoaderLimits.maxMethodBytes` is one block (32,760 bytes), which keeps every jump within Int16. `CodeReader.read` in `LiveMethods.swift` checks no bytecode length, and `LiveMethodHeap.bytes` allows up to `maxLargeCount`.
- Path that breaks it: a keyword send of 256 arguments, or a block copying 256 values, raises `ByteArray at:put:`'s Error, not a CompileError, so `Behavior>>compile:` callers that handle CompileError do not catch it. A method whose inlined `ifTrue:` body exceeds 32 KiB of bytecode gets a wrapped offset. If the verifier finds the target at an instruction boundary with the same depth, the method verifies and runs the wrong code.
- Neighbours that have it right: the Swift assembler.
- Test that would fail today: CompilerTest: a 256-argument keyword send must signal CompileError; a method of 40 KiB of bytecode must be refused.
- Fix sketch: check each operand's range in `assembleWithExtraLiterals:` and signal CompileError (the `jump too far` and size limits as the assembler has them). Bound the bytecode length in the make primitive by `LoaderLimits.maxMethodBytes`.

### F15. Smaller compiler disagreements (the comparison test exercises only the kernel's own methods)
- Severity: low   Confidence: confirmed
- Where: `kernel/Compiler/Compiler.class.st` `inlinable:` and `isIntegerLiteral:` (`isInteger`, so LargeIntegers count) against `Compiler.swift` (`.integer`, SmallIntegers only). Also the ST `compile:` `primitive:` handling (no 1...255 check, no "two primitives", `<primitive: 0>` accepted) against `Compiler.swift:859`.
- Invariant: "The rules both compilers follow, exactly (a difference is a test failure)" (`Compiler.swift` header).
- Path that breaks it: `1 to: 10 by: (2 raisedTo: 70) do: [:i | ...]` is inlined by the kernel compiler only. `1 to: 100000000000000000000 do:` gets a hidden limit temp in Swift only. Either way the debugger's `frameVariablesOf:` (which recompiles with the kernel compiler) can disagree with an image-built method. `<primitive: 0>` and two primitive pragmas compile live and are refused by the build.
- Test that would fail today: CompilerTest compiling such sources with both compilers through the existing comparison harness.
- Fix sketch: use the same predicate (`SmallInteger`) in the kernel compiler, and copy the primitive pragma checks.

### F16. The compiler that takes untrusted protocol input is never syntax-fuzzed, and its limits have no tests
- Severity: medium (a test weaker than its invariant)   Confidence: confirmed
- Where: `Sources/KajoCompiler/FuzzSyntax.swift` and `Sources/fuzz-syntax/main.swift` fuzz the bootstrap compiler only. `kernel/Tests/CompilerTest.class.st` has five tests (no nesting-limit test, no long chain, no invalid tokens beyond `testParserErrors`). MakeFuzzTest mutates compiled code, not syntax.
- Invariant: "every method the protocol compiles is untrusted"; the Smalltalk compiler (Behavior>>compile:, `evaluate`, `method.compile`) is the one that compiles them.
- Path that breaks it: F6, F7, F14 and F15 are all in code no fuzzer reaches.
- Test that would fail today: a kernel test (or a `fuzz-syntax` mode) that feeds the syntax fuzzer's corpus through `Compiler compile:in:` in a VM and requires a CompiledCode or a CompileError for every input. That would find F6, and F7 when compared with the Swift result.
- Fix sketch: add a make-and-run mode to `fuzz-syntax` that also compiles each input with the kernel compiler inside a VM (`runToCompletion`), and compare acceptance.

### F17. Temporaries of an inlined loop body keep their value across passes unless a closure captures them
- Severity: low   Confidence: confirmed (by reading both compilers; they agree)
- Where: `Compiler.swift` `genInlinedBody` and `kernel/Compiler/Compiler.class.st` `genInlinedBody:in:on:value:`. A fresh vector per pass nils the captured and assigned temps; the frame temps of the body are never reset.
- Invariant: object-model / kernel-live: "a closure made in one iteration keeps that iteration's values" (Pharo's rule, under which Opal also nils every temp of an inlined loop body on each pass).
- Path that breaks it: `1 to: 3 do: [:i | | t | t isNil ifTrue: [t := 0]. t := t + 1. out add: t]` adds 1, 2, 3. Adding an unrelated `[t] value` in the body makes `t` captured and assigned, so it lives in a fresh vector per pass and the loop adds 1, 1, 1. An unrelated closure changes the answer.
- Test that would fail today: BlockClosureTest asserting both forms give the same result.
- Fix sketch: emit `push_nil; store_temp; pop` for each non-vector temp of a loop body at the start of each pass, in both compilers (the plain code and its fusion are unaffected).

## Checked and sound
- Both scanners: unterminated string and comment at end of input are refused with the start line; NUL and invalid UTF-8 are refused (Swift validates every scalar; Strings in the image are valid UTF-8 by `asStringValidating`); a radix outside 2...36, more than 4000 digits and an exponent above 4000 are refused in both; integers past ±2^62 become LargeInteger literals with the same boundary as `Oop.smallIntegerMax/Min`; `x--1` and `3 - -2` split identically; `#foo:bar` symbols, `#(foo:bar:)` keyword joining by adjacency, byte arrays 0...255.
- Nesting: both parsers count blocks, parentheses, braces, literal arrays and assignments against 32 with `enter`, and chains are loops in both parsers. Swift analysis and generation walk chains by `Compiler.chain` and `SendNode.deinit` releases chains iteratively.
- Inlining rules, hidden temps, the loop-body vector rule, frame layout order (arguments, copied, vector, locals and loop vectors by sequence number), `copiedIndex`, cascade on `super` (`sendSuper` per part in both), cascade whose first message would be inlined (sent, not inlined, in both), `thisContext`, refusal of assignment to arguments, inlined arguments, `self`, `super` and `thisContext`, class-variable read and write through the Binding with `value`/`value:`, doits ending with `returnTop`: identical in both compilers.
- `ProjectWriter.apply` (the client side of `files`) refuses any path that is not `<File>.class.st`/`.extension.st` or `<Tag>/<File>.class.st` with a safe tag, and never follows a link. A target cannot make a client write or remove outside its project. `ClassBuilder checkTag:` refuses `/`, NUL and leading `.`. The package name never becomes a path component.
- `DevProtocol take:`: the host has already validated the request shape (`Request.swift`: members, kind, args object). Unknown argument names are refused with a reply. A non-debuggable request's Error is an error reply. `finishActive:` turns an unwritable result into an error reply.
- `DebugStop frameAt:` checks that the index is an Integer in range. `stopOf:` errors for a Process that is not stopped. The cap of 32 counts error stops under the Debugger lock.
- `String>>do:`'s fast path: primitive 126 counts non-continuation bytes, Strings are immutable (`at:put:` is an error) and valid UTF-8, so `scalarCount = byteSize` holds exactly when every byte is ASCII.
- `Integer>>printString:` refuses bases outside 2...36, handles 0 and negatives, and sizes the ByteArray from a digit count it divides out first.
- `Interval` and `to:by:do:` refuse step 0; `OrderedCollection removeFirst`/`removeLast` on empty are errors; `String replaceAll:with:` with an empty pattern answers the receiver; `Dictionary at:put:` refuses a nil key.
- Tonel readers (Swift and Smalltalk) agree rule for rule: comment quote doubling, STON depth 16, `#category`/`#package`/`#tag` and unknown keys ignored, a method of another class refused, class side detection, bracket matching skipping strings, comments and `$x` (multi-byte too), and `tonelTag(ofPath:)` against `tagOfPath:`.
- `Behavior>>compile:classified:` forgets the replaced method's source (no growth per recompile, apart from F4's races). `removeSelector:` keeps the pragma index, source, category and package in step.
- `Smalltalk classNamed:` after 211a6ee reads the table once and rebuilds into a temporary. `DevProtocol rebuildKinds` builds before it publishes.

## Not read
- `tools/` (the developer UI package), `kernel/UI/*`, `kernel/Development/Json*`, `ClientTransport`, `kernel/Streams/*`, `kernel/Text/Symbol`, `Utf8View`, `Character` (beyond `isSeparator`/`isLetter`), `kernel/Processes/{Delay,Monitor,SharedQueue,Process (most),ProcessorScheduler,Ephemeron,Unwinding}`, `kernel/Collections/{Set,IdentitySet,WeakArray,SequenceableCollection,Array,Association}` in detail, `kernel/Numbers/{LargeNegativeInteger,Number (most),Magnitude}`, `kernel/System/{TonelLoader,TonelDocument}`, and most of `Smalltalk.class.st` (writeTonel, the image-save paths). WeakArray and the weak symbol table during marking were not traced.
- The SUnit tests in `kernel/Tests/` beyond CompilerTest, the ExceptionTest pass/outer test and the MakeFuzzTest header. `Tests/KajoCompilerTests/*` were listed, not read.
- docs: I read the briefs' rules through the code comments and AGENTS.md. I did not read `kernel.md`, `kernel-image.md`, `kernel-live.md`, `live-classes.md`, `tags-as-subdirectories.md`, `collections-speed.md`, `development-protocol.md`, `development-answers.md` or `object-model.md` in full. ADR 0009 was read only for §12.
- No build, test or fuzzer was run (no finding needed the one allowed run to settle a critical question).
