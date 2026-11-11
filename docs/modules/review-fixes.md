# The second review's fixes

The owner asked on 2026-11-10 for a thorough review of the whole implementation.
Five Opus reviewers read the tree at d78afcc in parallel, read-only, one area
each (the collectors; the interpreter, loader, workers and Processes; the
primitives, the shell surface and the development protocol; the compilers and
the kernel; the tools, app, shells, generator, CLI and scripts). Their reports
are `docs/reviews/2026-11-10/<area>.md`, 42 findings in all, each with the
invariant, the breaking path, the neighbours that keep it, a test and a fix
sketch. The main session confirmed the top ones in the code before this brief
(primitive 93, `zeroLongBytes`, the accept loop, `Connection.send` after
`close`, the `DevClient` resend list, the hosts' `Int64(d)`, `Transcript
show:`, the retry marker, `check-tier.sh`'s `*.md` rule and the matrix gate's
status). A finding is named below as `<area>.F<n>`.

This module fixes them in two parts, each one agent and one gate run: part 1
is everything critical or high plus the medium items in the same files (the
VM, the protocol transport, the kernel's exceptions, Transcript and
registries, the hosts' numbers, the client's resend list); part 2 is the
rest (the compilers' agreement, Tonel, the tools, the scripts, the lows).
Every fix comes with the test the report describes (one that fails on
d78afcc), or says why none can.

## Part 1 (this agent)

### Critical

1. **`primitives.F1` = `interpreter.F1`: primitive 93 un-protects verified
   code.** `ObjectModelPrimitives.swift` case 93 refuses only a receiver of a
   sealed class; a made method's bytecodes ByteArray and literal Array are
   read-only and pinned for good but not sealed, and `slotAt:` (117) reaches
   them from the Method. Fix: 93 refuses to clear the bit of an object pinned
   for good (`Header.isPinnedForGood`; a frame pin is not that), in every
   build. Check that nothing legitimate clears the bit on a pinned object
   (grep `pinForGood` callers: method parts, what else?) and that `beWritable`
   on an ordinary read-only object still works. Test: a kernel test and a
   Swift test that `(Object >> #printString) slotAt: k` then `beWritable`
   answers failure for the bytecodes and the literals and the method still
   runs; a `ReadOnlyTest` that an ordinary read-only Array can be made
   writable. Say in the doc whether any other path (97/98, `become:`,
   `forward`, reshape, primitive 38 into a read-only target, `instVarAt:put:`
   on a Method) can reach those parts: trace each.
2. **`collectors.F1`: `zeroLongBytes` polls without rechecking.**
   `LongBytes.swift:86-107`: after a `byteWorkPoll` that parked, re-read the
   object's body words and offset as `copyBytesPolled` does; if the length
   changed (a `become:` in a stop), stop zeroing (whatever the object became
   is already whole). Bound every `zeroBytes` chunk by the length read after
   the poll, with a real check, not an `assert`. And keep an object that is
   still being initialised out of the instance walks: either set the old-map
   bit after the fill (check every reader of the bit: the marker's snapshot,
   the sweeps, the instance walks, the verifier) or have `walkInstances` and
   `walkPointers` skip pending roots (`collectors.F4` is the same exposure for
   `fillFresh`'s partial Strings; choose one mechanism for both and write why).
   Test: a VM test with 2 workers under `collectAtEveryAllocation` or a stop
   stress where one Process allocates a long ByteArray while another runs
   `ByteArray allInstances` and `become:`s what it finds with a short
   ByteArray; it must trap on d78afcc (run it by hand there and record the
   trap in the doc, as the rules say a trapping variant is) and pass after.

### High

3. **`interpreter.F2`: `process.suspend` of a waiting Process.**
   `Debugging.swift` `interrupt(kind: debugStop)` on a waiting Process
   unlinks it from its Semaphore and makes it ready with
   `debugStopAfterSend`; proceeding returns from `wait` unsignalled. Fix so
   that a proceed re-enters the wait: the simplest sound shape is to leave the
   stop's pc at the `wait` send (as a poll's rewind does for a running
   Process) so proceeding re-executes the send and the Process waits again
   (or passes if the Semaphore has excess signals); say how the suspended
   primitive's operands are restored (`suspendAfterPrimitiveLocked`). Kind 1
   (terminate) keeps unlinking. Test: a Process in `aSemaphore critical:`
   suspended through the protocol and proceeded does not enter the critical
   section until the Semaphore is signalled.
4. **`primitives.F2`: the accept loop and unpaired connections.**
   `Server.swift` `acceptLoop` returns on any error but `EINTR`: on
   `EMFILE`, `ENFILE`, `ECONNABORTED`, `EAGAIN` it sleeps a bounded moment
   (10 to 100 ms) and continues; only a closed listener ends it. A
   connection that has not presented the token is bounded: at most 8 such
   at once (a new one closes the oldest unauthenticated), at most 4 KiB
   buffered before the token line and 5 s to present it; the limits are
   constants named in the doc. Test: 20 connections that send nothing are
   accepted and closed and a paired client still connects; a connection
   sending 1 MiB without a newline is closed.
5. **`primitives.F3`: a write enqueued after `close`.** `Server.swift`
   `Connection.send`/`close` and `ClientHost.swift` `ClientConnection`: the
   `queue.async` of the write happens under the same lock that reads
   `closed`, or the queued block re-checks `closed` under the lock before
   writing; the descriptor is closed once, after every write, and never
   under a write. Test: a stress of concurrent sends and a close with the
   assertion that no write happens after the close (count under the lock).
6. **`primitives.F4`: the image never hears `session.close` when the server
   ends a connection.** `replaceToken`, `dropConnections`, the 64 MiB
   backlog drop and `stop` set `closed` first and the reader never posts.
   Fix: every server-side end posts the session's close to the image once
   (the reader's path or the closer's, never both). Test: New token with an
   open session leaves no `DevSession` in `Smalltalk sessions` (or whatever
   the registry is).
7. **`kernel.F1`: `Transcript show:` inside the lock.** `displayString`,
   `printString` and the `nextPutAll:` of a non-String run outside
   `critical:`; inside it only the stream's `nextPutAll:` of a String and
   the contents read. Test: `Transcript show: anObjectWhoseDisplayStringFails`
   reports the error and a following `Transcript showLine:` still works.
8. **`kernel.F2`: the retry marker is `ExceptionSet`.** A private object
   nothing else answers (a class-side instance of a private class, or a
   unique `Object new` held in a class variable created at build). Test:
   `[ExceptionSet] on: Error do: [:e | nil]` answers `ExceptionSet`.
9. **`kernel.F3`: `Exception>>outer` leaves `handlerContext` on the outer
   handler**, and `kernel.F10` (`pass` with no outer handler returns from the
   inner `on:do:` instead of resuming at the signal for a resumable
   exception; `retryUsing:` runs its block inside the busy handler): fix the
   three against ANSI's semantics (Pharo's `Exception>>outer`, `pass` and
   `retryUsing:` are the reference, not to copy). Tests: the report's
   examples (`x * 10` runs after an outer `resume: 1`; `[Notification
   signal. #after] on: Notification do: [:e | e pass]` answers `#after`).
10. **`kernel.F4` and `kernel.F5`: unsynchronized registries.** `Smalltalk`'s
    sources, organizations, packages, definitions and undeclared tables, the
    Pragma index, `DevSession`'s handles and `nextHandle`, `DevProtocol`'s
    argument names: each gets the lock its neighbours have (the pending,
    sessions, stops, View registry and Delay tables are locked: use the same
    shape), and every rebuild (`Pragma rebuildIndex`, `rehashTo:`,
    `rebuildKinds`) builds in a temporary and publishes whole, as
    `rebuildClassNames` does since 211a6ee. Grep the kernel for every
    `:= IdentityDictionary new` / `:= Dictionary new` / `:= Array new:` on a
    class-side variable followed by a fill, and list them in the doc with
    what each became. Test: `handleOf:` from 8 Processes at once never
    answers the same handle twice; a class redefinition from 4 request
    Processes at once leaves `Pragma allNamed:` complete.
11. **`interpreter.F3`: test primitive 39 (`slowPeek:`)** is dispatched in
    every build and reads weak slots without `keepAliveRead`. Fix: either
    `keepAliveRead` on its read and the compiler refusing it outside the
    tests' build, or the primitive gone from the product build behind the
    same switch the other test-only paths use; say which and why.
12. **`tools.F1`: the hosts' `num()`.** `AppKitHost.swift:234` and
    `UIKitHost.swift:213`: `.int` only when `abs(d) < 2^53` (and the other
    `Int64(` of a Double in `KajoApp`, each checked), `.double` otherwise.
    Test: `ShellTests` sets a view's width to `1.0e20` and reads it back.
13. **`tools.F2`: the resend list.** `DevClient` (`tools/Client/DevClient.class.st:577`)
    holds back after a reconnect every request that changes a Process or
    removes code: `process.proceed`, `process.restart`, `process.retrySend`,
    `process.terminate`, `process.suspend`, `process.step`, `method.remove`,
    `class.remove`, beside the four it holds back today; a held-back request
    answers its block an error naming the dropped link (as `evaluate` does).
    Test in `tools/Tests/DevClientTest`.
14. **`kernel.F12`: `critical:` loses its lock when the Process is
    terminated between `wait` and `ensure:`.** The wait goes inside the
    `ensure:`'s receiver block with a flag that says whether it was acquired
    (Pharo's `Semaphore>>critical:` shape), for `Semaphore` and `Mutex`.
    Test: terminate a Process parked in `critical:`'s wait and assert the
    Semaphore still has its one signal.
15. **`kernel.F13`: a client can suspend or terminate the protocol Process
    itself.** `process.suspend`, `process.terminate`, `process.step` and
    `process.evaluate` on the protocol's own Process answer a refusal reply.

### Medium in the same files

16. `primitives.F5`: the JSON reader's duplicate-key check is quadratic:
    a Set of the keys per object (`JSON.swift:124`), on both sides.
17. `primitives.F6`: primitive 148's temporary file has a fixed name and
    the write is not serialized: a per-write unique name in the same
    directory (`mkstemp`-style, `O_CREAT | O_EXCL` kept, `O_NOFOLLOW`) and
    one `rename` over the target; two concurrent writes of one file leave
    one writer's whole text, never a mix.
18. `primitives.F7`'s second half: `ProjectWriter`'s remove never removes a
    directory and never recurses (a directory named `X.class.st` is a
    refusal); the first half (the image chooses the project directory) is
    the owner's, question 1 below: build nothing for it.
19. `primitives.F9`: primitives 154 and 160 dequeue before they allocate;
    allocate first (or put the item back on failure) so a heap-full
    failure loses nothing.
20. `primitives.F10`: a `ShellProcess` used after `release` is checked (the
    entry's generation or a released flag), a refusal, never a read of
    whatever reused the entry.
21. `collectors.F2`: primitive 38's pointer copy and the pointer
    `shallowCopy` over a large object poll between chunks as the byte
    versions do (the barriers per store stay); `collectors.F3`: the final
    mark's weak-slot pass is bounded or polled per 4096 slots like the
    marker's large-object scan, and the doc says what the bound is.
22. `kernel.F11`: `Fraction` and `Float` that are `=` hash alike
    (`Fraction>>hash` as the Float's when it has one, Pharo's rule).
23. `interpreter.F4`: primitive 156's frame-position assumption against a
    frame made by an interrupt: check it, refuse when the running frame is
    an interrupt's (`FrameMarker.discard`), test it.
24. `interpreter.F5`: a pending interrupt or terminate request is in the
    host record only; say in the doc what a save does with it today
    (refuse the save while one is pending, as `processesHaveFrames` refuses,
    is the cheapest sound answer) and build that.

### Bar

- Every fix above has its test, failing on d78afcc where a test can (say
  which cannot and why); the two critical ones also run by hand on d78afcc
  with the trap or the rewritten bytecodes recorded in the doc.
- `interpret` identical instruction for instruction (`just arc-check` and the
  disassembly diff against d78afcc); the aligned A/B within noise.
- Primitive 93's refusal, 148's new temporary name and 38's polls in
  `ExtremeIntegerTests` where they take an integer.
- The protocol fuzzer runs 120 s on the changed reader with "libFuzzer
  build: ok".
- `just check d78afcc` on the final code commit: the core tier (the VM
  changes), every gate; the Mac and iPhone matrices' `--bar` as before.
- The round trip (`scripts/canonical-tonel.sh --check`) clean on every
  kernel commit.

### Open questions for the owner (build the recommended option; list them)

1. `primitives.F7`: the image names the client's project directory in
   `ClientHost connect`, so Smalltalk code in a development image can make
   the host write and remove `.class.st` files in any directory the user can
   write. Recommended: the host decides (the Kajo app's product mode and
   `kajo run --project` already know the directory; the tools ask the host
   for it by a `project` op instead of passing one), a later follow-up with
   the owner's answer. Not built here.
2. `primitives.F2`'s limits (8 unauthenticated connections, 4 KiB, 5 s):
   recommended as named; say if the phone's pairing flow needs more.
3. `interpreter.F2`: a suspended waiting Process re-waits on proceed
   (recommended) against Pharo's behaviour of resuming it as signalled.

## Part 2 (briefed 2026-11-10, after part 1's hand-back)

The rest of the review: the findings part 1 left, the reports' notes, and
part 1's own "not done" where a test or a fix is cheap. Each item names its
finding; read the full entry in `docs/reviews/2026-11-10/` (the invariant,
the path, the neighbours, the proposed test) before building it. One finding
or one coherent group per commit, named by its `<area>.F<n>`.

### The two compilers agree, and refuse alike

1. **`kernel.F6`: recursion over untrusted or cyclic input.** The Smalltalk
   compiler's `analyze:in:` and `gen:in:on:value:` recurse on a message's
   receiver, so a chain of thousands of unary sends (the report's 200 000
   ` abs`) overflows the request Process's stack, which ends in a VMError
   with no reply and a `pending` entry that is never removed. Walk chains
   by loops as the bootstrap's `Compiler.chain` does (the
   reserve-and-depth follow-up's rule: chains are loops, the rest is
   bounded at 32). `DevSession printOf:` and `DebugStop>>frameDetail:
   session:` print through a bounded stream with a set of the objects
   being printed, so a cyclic collection answers a cut text, not a stack
   overflow (and `DevSession>>describe:` no longer prints a whole
   collection before cutting it, the discoverability doc's "not done").
   And the net under both: `DevProtocol run:` answers an error reply when
   its request Process ends without one, whatever ended it, so no request
   waits for its client's timeout and `pending` does not leak. Tests: the
   chain over the protocol answers a reply within a bound; a collection
   that holds itself prints; a request whose Process is terminated from
   outside is answered.
2. **`kernel.F7`: one identifier rule.** The bootstrap's scanner
   (`Syntax.swift`: a letter is ASCII or `Unicode.Scalar.properties.
   isAlphabetic`, a run continues over letters, digits and scalars with a
   numeric type) and the kernel's (`Scanner>>isLetterAt:`: any
   non-separator scalar above 127) disagree, so the live system accepts a
   method the image build refuses. The kernel's scanner follows the
   bootstrap's rule, by construction: one primitive that answers the
   bootstrap's own predicate for a scalar (the same Swift function, moved
   where both can call it), not a second table. Tests: both compilers on
   U+00D7, U+00B7, U+2192, U+1F600, U+00A0, a combining mark and a
   non-ASCII digit, at the start and inside an identifier, agreeing on
   accept and refuse; the new primitive in `ExtremeIntegerTests`.
3. **`kernel.F8`: a `[` in a pattern comment.** `at: i "index in [1,
   size]" put: v` is written as it was typed and neither Tonel reader
   finds the pattern's end. Both readers (`Tonel.swift` and
   `TonelReader>>readMethodInto:`) skip comments while looking for the
   pattern's `[`; the writer and the canonical form do not change, no
   file is rewritten. Tests: the method round-trips byte for byte through
   both readers; a seed for the syntax fuzzer.
4. **`kernel.F9`: a redefinition against the subtree's names.** Primitive
   146 re-checks the class but not its subclasses: a live redefinition can
   give a class a class variable a subclass declares, or an instance
   variable that clashes below it, and the image build then refuses the
   written sources. The primitive is the trust boundary: 146 runs
   `ClassRules`' names rule for the class and every subclass against the
   new shape before anything changes and answers the reason as a value;
   `ClassBuilder redefine:` turns it into the usual error. Tests: each
   clash refused with nothing changed; the reshape-spec mutation test
   asserts that the image after every accepted redefinition passes the
   build's rules over every class.
5. **`kernel.F14`: the generator refuses what the assembler refuses.**
   `BytecodeGenerator assembleWithExtraLiterals:` encodes without range
   checks (a jump offset wraps, a count past its field is a generic
   Error); every operand gets its refusal as a CompileError naming the
   limit, the same limits as `Assembler.swift`. The make primitive (143)
   bounds what it is handed by `LoaderLimits` (bytecode length by
   `maxMethodBytes`, the literal count) as the assembler does, before the
   verifier runs. Tests at each limit and one past it, in both compilers
   ("every count a bytecode encodes has a refusal and a test at its
   limit").
6. **`kernel.F15`: the smaller disagreements.** Inlining and
   integer-literal decisions use SmallInteger-ness as the bootstrap does
   (not `isInteger`, which a LargeInteger literal answers too);
   `<primitive:>` is refused out of range, twice in a method and at 0, as
   `Compiler.swift` refuses it. Beside them a corpus: a fixture of
   methods that exercises each construct at and past its limits, beyond
   the kernel's own methods, compared between the compilers bytecode for
   bytecode in the plain form (primitive 166) and refusal for refusal.
7. **`kernel.F16`: the kernel's compiler is fuzzed.** `fuzz-syntax` gains
   a mode in which each input is also compiled by the kernel's compiler
   in a VM through the make primitive (beside the make-and-run mode of
   8d, `FuzzEntry.makeAndRun`, which already holds an image) and the two
   outcomes compared: both refuse, or both accept with
   the same plain bytecodes and literals. A disagreement is a finding:
   fixed here, or listed with its input as a fixture. Run it 600 s with
   "libFuzzer build: ok" once the items above are in, on a thread with
   the smallest stack the compiler runs on.
8. **`kernel.F17`: document.** A temporary declared in an inlined loop
   body that no closure captures keeps its value across passes, in both
   compilers. Say so in `docs/modules/kernel-live.md` beside the
   per-iteration rule, with what Pharo does, and pin it with one test
   both compilers pass. No code change (open question 3).

### The tools and the scripts

9. **`tools.F3`: evaluate the selection once.** "Instances of it",
   "Objects pointing to it" and the Inspector's pointers-to-slot evaluate
   the selected text two or three times, so a selection with a side
   effect runs it each time. Evaluate once to a handle, then ask about
   the handle. Test in `DiscoverabilityTest` with `FakeDevClient`
   counting the evaluations of the selection: one.
10. **`tools.F4`: the tier of a fixture and of a rename.**
    `check-tier.sh` classifies `Tests/**/*.md` fixtures as docs (the perf
    report's golden files, the app project's README) and judges a rename
    by its new path only. `Tests/*` is classified before `*.md`; both
    diffs run with `--no-renames`, so a file moved out of the core still
    owes the core tier. Cases in `check-tier-test.sh` for each.
11. **`tools.F5`: a matrix gate fails when any step fails.** The Mac
    matrix's brace group and `device-rows.sh` take their status from
    `shell-report.py --bar` alone: a matrix that died early or a report
    that failed passes. Every step's status counts, and `--bar` over a
    directory with no rows exits 1 saying so. Tests: `shell-report.py
    --bar` has none yet, so a fixture directory with rows and one without
    (run by `check-tier-test.sh` or a script test beside it), and the
    gate's command with a failing first step fails.
12. **`tools.F6`: the small items**, each its own commit: the `sudo ln`
    line the app shows quotes its paths; two launches at once never label
    a complete checkout incomplete (`CheckoutInstaller.install`); the
    `kajo` target builds with strict memory safety (a clean build to
    count what it flags; nothing outside the core should need `unsafe`,
    so say what does); `new-check.sh`'s "0 symbols" check has a positive
    control (the Debug binary has some, or a broken pattern passes);
    `dist.sh` asserts the frameworks' compile flags from the build log
    instead of recording them (exercised by `dist.sh checkout` in `just
    new-check`; no signed `dist` run is owed); and `Development.swift`'s
    `Host.current().localizedName` on the main thread is traced with the
    launch trace on the Mac and moved off it if it can wait (the
    `hostName` lesson).
13. **`primitives.F8`: the client's reader.** `ProtocolClient` reads
    lines of any length and closes its descriptor after 1 s whether or
    not its reader has ended. Lines are bounded as the server's are (the
    limit refused and the rest of the line discarded, a reply and not a
    hang), and the descriptor is closed once, by whoever ends last, as
    part 1's `Connection.finish` does. Tests: a target that sends a line
    past the limit; a close while the reader is in `read`, the descriptor
    closed exactly once.

### The reports' notes

14. `PairingTokenStore.renew` answers the new token only when it was
    written whole and renamed into place; otherwise the old token stands
    and the failure is reported. `load` checks the file's mode: a token
    file anyone else could read is replaced by a new token (open question
    2). No token in a test's output, a log or the doc.
15. `ClientHost.run` stamps a reply's `line` event when the line was
    read, before `ProjectWriter.apply`'s file writes ("timestamp events
    with the time they happened").
16. `ShellBridge.post` against a concurrent re-registration: the report
    reads the worst case as a spurious signal to another Semaphore that
    reused the entry. An excess signal on a Mutex's Semaphore breaks
    mutual exclusion, so trace it: if the path exists, close it (the
    queued signal holds its Semaphore by a root the drain releases, or
    the registration takes the lock the post holds) with the test that
    fails without it; if it does not, write the trace down.
17. Recorded, not built: a spoofed Bonjour name receives the token (plain
    TCP now, PSK-TLS later, the owner's decision of 9d); ten wrong tokens
    a minute pause the listener (by design).

### Part 1's "not done"

18. Tests owed: the accept loop's failure path through an injected
    `accept` result (not by lowering the process's descriptor limit); the
    client side of item 5 (`ClientConnection`); primitive 154's put-back
    on its own.
19. A waiting Process loaded from an image gets its wait length at load
    (the loader already decodes its method to check the frame's depth at
    the saved pc; the instruction before that pc is the send), so its
    debug stop rewinds as a live one's does. No image format change; if
    one is needed, stop and leave it listed.
20. The final mark's weak pass measured in a release build
    (`theWeakPassIsMeasuredPerSlot`'s kernel at 2^20 and 2^24 - 1 slots),
    the number beside part 1's debug one. A measurement, not a change
    (open question 4 of part 1).

Left as part 1 left it, by decision: `UIEventLoop`'s tables and the
tools' class-side tables stay unsynchronized (main-affine UI state).

### Bar

- Every fix has its test, failing on the starting commit where a test
  can (say which cannot and why), the outputs in `failing-before.txt`.
- The two compilers agree on every method of the image (`CompilerTest`),
  on the new corpus and under the new fuzz mode's 600 s; every
  disagreement the fuzzer finds is fixed or listed with its input.
- `interpret` identical instruction for instruction (`just arc-check`,
  the disassembly diff); the aligned A/B within noise.
- New primitives and the make primitive's new refusals in
  `ExtremeIntegerTests` where they take an integer.
- The round trip (`scripts/canonical-tonel.sh --check`) clean on every
  kernel and tools commit.
- `scripts/check-tier-test.sh` with its new cases and the perf report's
  fixture test pass.
- `just check <base>` on the final code commit: the core tier (the make
  primitive, 146, the loader), every gate, the Mac and iPhone matrices'
  `--bar` as before.

### Open questions for the owner (build the recommended option; list them)

1. `kernel.F7`: identifiers follow the bootstrap's rule (Unicode
   alphabetic, from the host's tables through one primitive), against
   ASCII-only identifiers in both compilers (no table, no difference
   between hosts' Unicode versions). Recommended: the bootstrap's rule.
2. Note 14: a token file with a mode wider than 0600 is replaced by a new
   token (recommended; pairing is repeated once), against tightening the
   mode and keeping the token.
3. `kernel.F17`: document the loop body's uncaptured temps (recommended,
   three bytecodes a pass saved and no method of the kernel depends on
   either answer), against nilling them at every pass.

## As built (part 1)

Built 2026-11-10 on master from 8a8847d (the code d78afcc's), one finding
or one group per commit, every one named by its `<area>.F<n>`. The tests
live beside their neighbours or in `Tests/KajoVMTests/ReviewFixes/` and
`Tests/KajoCompilerTests/ReviewFixes{Kernel,Transport}Tests.swift`; each
was run on 8a8847d in a worktree (adapted only where the test needs an API
the fix adds; said per item) and the outputs are in the hand-back's
`failing-before.txt`.

### Critical

**1. `primitives.F1` = `interpreter.F1`: primitive 93** (18038c7). Case 93
refuses to clear the read-only bit of an object pinned for good (setting
it still works; a frame pin does not refuse). Every object the VM makes
read-only is now pinned for good: the method parts, literals and Symbols
were; class pools (the image build's `allocatePinned`, 145's and 146's
pools) and a method's Pragmas and their argument Arrays (`MethodBuilding`)
joined them. `grep pinForGood`: methods, bytecodes, literal frames,
literals (`readOnlyPinned`), Symbols (`intern`, primitive 135's interning),
classes and metaclasses (image build, 145), nil, true, false; nothing
legitimately clears the bit of any of them (no kernel caller of
`beWritable` but the test of an ordinary Array). Tests:
`ReadOnlyTests.primitive93NeverUnprotectsAMethodsParts` (the bytecodes,
the literal frame, another method's frame and a Symbol refuse; setting
works; the method runs; an ordinary read-only Array becomes writable) and
`ReadOnlyTest>>testAMethodsPartsStayReadOnly`. On 8a8847d the kernel test
fails ("Expected Error to be signaled"), and the hand run (a temporary
`HandRunTest` in the worktree: compile `victim ^ 7`, clear the bytecodes'
bit, write `push_temp 255; return_top`, run it) printed

    hand-run before: #[11 7 13] readOnly=true
    hand-run setReadOnly: false answered true
    hand-run after: #[0 255 13] readOnly=false
    hand-run literals setReadOnly: false answered true
    KajoVM/ObjectMemory.swift:208: Assertion failed      (exit 133)

The other paths to a method's parts, traced: 97 and 98 install or remove
a whole method the make primitive verified, they never write into one;
`become:` (primitive 8) refuses read-only objects on both sides and sealed
classes (`Machine.become`); `becomeForward` is not dispatched from
Smalltalk (primitive 9 is not in the table; only 146's own forwarding
uses it); a reshape refuses read-only instances (`ReshapeError.
readOnlyInstance`) and Array and ByteArray are kernel classes 146 does not
reshape into a method's parts anyway; primitive 38 refuses a read-only
receiver (pointers and bytes), 2 refuses read-only receivers and Strings
and Symbols, 128 refuses read-only; `instVarAt:put:` refuses a sealed
receiver (a Method) and stores through the read-only check; `slotAt:put:`
does not exist (the make primitive refuses it with `instVarAt:put:`,
`become:` and `becomeForward:` as literals of sealed extensions). None
reaches them now that 93 cannot clear the bit.

**2. `collectors.F1` and `F4`: the zeroing and the walks** (26dcf96).
One mechanism for both: a pending root carries a "building" mark
(`registerPending(…, building: true)`, `Machine.holdPending`, a byte table
`pendingBuilding` beside `pendingSlots` under `pendingLock`), and the walks
of 167 to 170 skip marked objects (`walkInstances` / `walkPointers`
`building:`, read in the stop). Chosen over setting the old-map bit after
the fill because the old map is read by the snapshot, both sweeps, the
verifiers and the walks, and an old entry without its bit is a state every
one of them would have to learn (the one-owner rule); a pending root is
already the object nothing else holds. Plain pending roots (Semaphores
waiting for host signals, the large-allocation trigger's root, the sweep
and marking waits' objects) are not marked and stay visible. And the
zeroing itself: `zeroLongBytes` re-reads its object's body words and
offset after a poll that parked and stops when either changed (counted
`zeroingCutOff`); `zeroBytes` checks used, bytes, large and the bound in
every build and answers false (it was an `assert`). Test switches
`buildingPauseUs` (a sleep between chunks, so a hunt lands inside) and
`walksSeeBuilding` (the broken variant). Tests (`ZeroingTests`): a hunter
Process running `ByteArray allInstances` and `become:`ing the first long
ByteArray it finds with an 8-byte one while another allocates one of
2^24 - 7 bytes: it finds it only whole, no cut-off; with the broken
variant it finds it mid-zeroing and the recheck stops the zeroing
(`zeroingCutOff >= 1`), the heap verifies. The same for a 1 MiB String
built by 123: no hunt sees a zero last byte, the broken variant does. On
8a8847d (the worktree given only the sleep switch) the first test traps:

    KajoVM/LongBytes.swift:172: Assertion failed      (signal 5)

### High

**3. `interpreter.F2`: suspending a waiting Process** (4769e88). The
Process record keeps the length of the `wait` send a Process suspended in
(`waitSendLength`, set by `waitSemaphore` under the scheduler lock); a
debug stop of a waiting Process rewinds its saved pc by it, so the stop is
the rewound kind (`stopForDebugger`, as a poll's) and proceeding sends
`wait` again. The argument for the operands: `wait` takes none, and
`suspendAfterPrimitiveLocked` wrote the primitive's result into the
receiver's slot, and 22's result is its receiver, the Semaphore: the stack
at the saved sp is exactly the send's operand at its start, the depth the
verifier traced there. A waiting Process loaded from an image has no
recorded length and stops after the send as before (not done). Terminate
keeps unlinking and unwinding from after the send. Test:
`DebuggerProtocolTests.aSuspendedWaiterWaitsAgainWhenProceeded` (a Process
in `critical:` behind a held mutex, suspended and proceeded through the
protocol, is waiting again and has not entered; a signal lets it in).

**4. `primitives.F2`: the accept loop** (7683253). Only a closed listener
ends the accept loop; any other `accept` failure is counted
(`acceptFailures`) and waited out, 10 ms doubling to 100 ms. A connection
that has not opened a session is bounded by `ProtocolServer.Limits`:
`unpairedConnections` 8 (a new one closes the oldest unpaired one),
`unpairedBytes` 4096 (newlines included, before its `session.open` line
ends), `unpairedNs` 5 s since it was accepted (the reader polls with the
remaining time); closes are counted (`unpairedClosed`). The session's own
lines keep the 16 MiB rule. Test:
`ReviewFixesTransportTests.connectionsWithoutASessionAreBounded` (20 idle
connections all closed, the first twelve by the cap and the last eight by
the time limit set to 2 s; 1 MiB with no newline closed; a paired client
served, with a line longer than 4 KiB). Limits of the fix: the `EMFILE`
path is not tested (lowering the descriptor limit of the test process
would starve the suite); the time and byte limits are per connection, so
a peer opening connections faster than 8 per 5 s churns the cap without
holding descriptors past it.

**5. `primitives.F3`: a write after close** (7683253). Server: `send`
enqueues its write under the lock that reads `closed`, `close` sets it and
enqueues the shutdown under it too, and the descriptor is closed once by
the connection's reader after its loop ends and the queue drained
(`Connection.finish`), so neither a queued write nor the reader's `read`
ever meets a reused number; a write block that meets the shutdown counts
`lateWrites` and writes nothing. Client (`ClientConnection`): writes
enqueued under the lock while `fd` is set, `drop` and `close` shut down
under it, `release` retires the descriptor under it and drains the queue
before closing. Test: `noWriteRunsAfterItsConnectionsClose` (eight
threads sending while a close comes, the old window held open by a sleep,
`lateWrites == 0` in 20 rounds). It cannot run on 8a8847d as it stands
(the counter is the fix's instrumentation); the client side has no test of
its own (the same shape).

**6. `primitives.F4`: session.close** (7683253). The reader posts
`session.close` whenever the session was opened (`wasOpened`), whoever
ended the connection; it is the only poster. `DevProtocol sessionCount`
reads the registry. Test: `aNewTokenTellsTheImageTheSessionEnded` (after
New token, and after `dropConnections`, the image holds only the new
session).

**7. `kernel.F1`: Transcript** (a0d9450). `show:` and `showLine:` make
their text with `textOf:` outside the lock (a String as it is, else its
`displayString`, which must answer a String); inside, only the String is
appended. Test: `TranscriptTest>>testAFailingDisplayStringLeavesThe
TranscriptUsable` (`TranscriptTestProbe`'s `printOn:` fails in a Process
that does not handle it; a following `showLine:` and a `showLine: 42` both
return within 30 s).

**8. `kernel.F2`: the retry marker** (10138db). `Exception
retryMarker` answers a private `Object new` held in Exception's class
variable `RetryMarker`, made by `Exception class>>initialize` at the image
build (and lazily in an image built without initialization). Test:
`ExceptionTest>>testRetryMarkerIsNoValueAProgramAnswers`.

**9. `kernel.F3` and `F10`: outer, pass, retryUsing:** (10138db). `outer`
saves `handlerContext`, searches through `outerSearch` (the frame a
resumption returns from), then restores it and sets the inner handler's
busy flag again; `outerContext` is cleared after the search. `pass` with
no enclosing handler resumes a resumable exception at its signal with the
default action's value (ANSI) and returns it from the `on:do:` otherwise.
`retryUsing:` puts its block in the `on:do:` frame's fifth temp and
returns the retry marker: `on:do:` unwinds and runs the block as its
protected block under the same handler. Tests: `testOuterLeavesTheInner
HandlerActive`, `testPassWithNoOuterHandlerResumesAResumableException`,
`testRetryUsingRunsTheBlockUnderTheSameHandler`. Deviation: the report's
first example (`[[x := Warning signal. x * 10] on: Warning do: [:e | e
outer + 1]] on: Warning do: [:e | e resume: 1]`) answers 2 under ANSI
(falling off the inner handler returns 2 from the inner `on:do:`), not 20
as the report wrote, and 2 on 8a8847d as well (from the outer one); the
test wraps it as `(…) * 100` to tell the two apart (200 now, 2 before) and
checks the report's 20 with `e resume: e outer + 1`.

**10. `kernel.F4` and `F5`: registries** (f25843a). One reentrant Mutex
`Smalltalk registry:` (made at the image build's first note) over
Smalltalk's sources, categories, packages, definitions and undeclared
Bindings, the pragma index and the Ephemeron registry; a Mutex per
DevSession for its handles; `DevProtocol critical:` (the protocol's lock)
for the argument names. Every rebuild fills a new table and publishes it
whole: `Pragma rebuildIndex` (under the registry lock, so no installation
in between is lost), `recordDefinitions:`, `replaceSources:`,
`HashedCollection>>rehashTo:`; `rebuildKinds` and `rebuildClassNames`
already did. Tests: `RegistryTest` (`handleOf:` from 8 Processes, 1600
distinct handles; 4 Processes compiling 40 methods each, every source
kept; the pragma index read 300 times while it is rebuilt 30 times).
Every class-side table filled in place, from the grep (class-side
variable assigned a new `IdentityDictionary`, `Dictionary`, `Set`,
`IdentitySet`, `OrderedCollection` or `Array` in a class-side method), and
what each became:

| Table | Where | Became |
|---|---|---|
| sources | `Smalltalk noteSource:of:`, `replaceSources:of:` | registry lock; replace builds the class's table first |
| organizations | `Smalltalk noteCategory:of:in:` | registry lock |
| packages | `Smalltalk notePackage:of:in:` | registry lock |
| definitions | `Smalltalk noteDefinition:of:`, `recordDefinitions:` | registry lock; recordDefinitions: builds then publishes |
| undeclared | `Smalltalk noteUndeclared:in:` | registry lock |
| classNames | `Smalltalk rebuildClassNames` | as 211a6ee built it (filled, then published) |
| PragmaIndex table | `Pragma rebuildIndex` | built in a temporary under the registry lock |
| argumentNames | `DevProtocol argumentNamesOf:` | the protocol's lock, parsed outside it |
| sessions, pending | `DevProtocol start` | made once at start; already under its lock |
| registry | `Ephemeron class>>registry` | registry lock around add and remove |
| stops, suspends | `Debugger class>>initialize` | made at the build; already under Debugger's lock |
| pending | `Delay class>>initialize` | made at the build; already locked |
| standing | `Unwinding class>>initialize` | made at the build; unchanged |
| registry | `View class>>initialize`, `resumeAfterSnapshot` | already under View's lock |
| timers, kindActions, frameActions | `UIEventLoop` | not changed: the event loop's main-affine state (UI code) |
| savedFrames, clients, debuggers, windows, connections, targetActions | `ToolWindow`, `DevTools`, `DevClient` (tools/) | not changed: the tools' UI Process only |

**11. `interpreter.F3`: primitive 39** (108a20b). Behind a VM test
switch, `VMTestSwitches.slowPeek` (the young-collection tests' runtime
sets it): every other VM's 39 fails at once. A runtime switch, like every
other test-only path here (`noBytePolls`, `walksSeeBuilding`, …), because
the tests and the product are the same build; there is no test-only build
to compile it out of. Without young collection its read goes through
`keepAliveRead`; with it the read is through an address held across a
blocking region on purpose (the epoch rule's test reads a reused eden in
its broken variant), which no barrier on the value can make sound. The
make primitive does not refuse 39 (with the switch off the primitive
fails and the method's own code runs). Test:
`testPrimitive39RunsOnlyWhenATestAsks` (both settings).

**12. `tools.F1`: the hosts' numbers** (e888d5a). `geometryValue` (one
function both hosts use, in `TextOffsets.swift`): a SmallInteger only for
a finite whole |d| < 2^53, a Double otherwise. The trace: the report's
path does not exist on AppKit, which keeps an NSView's frame within 2^45
(a width of 1.0e20 reads back 35 184 372 088 832, an integer, no trap),
but a non-finite value raised AppKit's exception at `set` (the test
process died on it, on 8a8847d as the before-run shows), and UIKit's
CALayer does the same; so every geometry argument of both hosts (x, y,
width, height, the frame and origin ops, the scroll position and the
divider) is finite or the call is refused (`geometryArgument`). The other
`Int64(` of a Double in `KajoApp`: none (the rest convert Ints and the
system's timestamps). Test: `aHugeGeometryReadsBackWithoutATrap` (AppKit
host; UIKit's path is the same function, built by `just apps`).

**13. `tools.F2`: the resend list** (95961a8). `DevClient class>>
notRetried` holds back `process.proceed`, `process.restart`,
`process.retrySend`, `process.terminate`, `process.suspend`,
`method.remove` and `class.remove` beside the four; each fails with the
error naming the dropped link. Test: `DevClientTest>>testADroppedLink
SendsNoCommandOrRemoveAgain`.

**14. `kernel.F12`: critical:** (e69525f). Semaphore and Mutex
`critical:` wait inside the `ensure:`'s protected block with `caught` set
right after the wait (Pharo's shape, the flag after the wait so a Process
the VM unlinks from its wait gives nothing back). That alone left one
window: a Process a signal released and asked to terminate before it ran
again took the terminate at its resume, before `caught := true`, and the
signal was lost. So the dequeue leaves such a terminate for the Process's
first poll (the record's `waitSendLength` says it was released from a
wait; the attention word and a countdown of 1 bring the poll at its next
send): `caught` is set first, with no send between. Deviation: a VM change
for a kernel item (in `dequeueLocked` and `runSlice`, not `interpret`).
Tests: `ReviewFixesKernelTests` driven slice by slice on one worker
(`CriticalProbe`): terminated while waiting, the Semaphore keeps its one
signal; released and terminated before it runs, the Semaphore and the
Mutex get theirs back. With the deferral switched off (by hand) the
second fails for both (excess 0).

**15. `kernel.F13`: the protocol Process** (da023f0). `DevSession>>
refuseServing:` answers an error for process.suspend, step, evaluate and
terminate of the protocol's own Process (`DevProtocol
isProtocolProcess:`). Test: `theProtocolProcessIsNotSuspendedOrTerminated`.

### Medium in the same files

16. `primitives.F5` (83310e2): the keys of an object in a `Set` in the one
JSON reader both sides use; `theDuplicateKeyCheckIsLinear` (100 000 keys
in a CPU budget). 17. `primitives.F6` (fd83f54): `writeTemporary(beside:)`,
`<path>.kajo-tmp-<16 hex digits>` per write, `O_CREAT | O_EXCL |
O_NOFOLLOW`, retried on `EEXIST`, never removing a name it did not create,
one `rename`; `twoWritersOfOneFileNeverTearIt`. 18. `primitives.F7`'s
second half (08d3495): a remove takes a regular file or a link (its own
type, not followed), a directory is a refusal; `aProjectRemoveNever
TakesADirectory`. 19. `primitives.F9` (e8bfa78): 154 and 160 put the item
back at the queue's head and signal for it again when they cannot
allocate (`ShellBridge.putBack`, `putBackRequest`;
`failAllocations` the tests' full heap); `aRequestTheImageCannotAllocate
IsNotLost` (154's path is the same shape, not tested on its own). 20.
`primitives.F10` (4db9370): `ShellVM` keeps the Processes it holds by id;
state, result, failure, wait, terminate and release of a released one are
refusals; `aReleasedShellProcessIsRefused`. 21. `collectors.F2` and `F3`
(c4fe338): 38's pointer copy and a large pointer object's `shallowCopy`
poll every `PointerWork.chunk` (32 768 slots, 256 KiB of words), 38 with
its hazard slots released for the poll and re-acquired, the copy a marked
pending root, a count changed by a stop a failure;
`thePointerCopiesPollBetweenChunks` (2^20 slots, longest stretch one
chunk). The final mark's weak pass is not bounded: it runs past the
commit point in the stop, which cannot poll, and moving it out of the
stop needs a read barrier that hides an unmarked referent from a weak read
until the pass has nilled it (a store-barrier-level change, outside this
part). Measured instead (`theWeakPassIsMeasuredPerSlot`, a WeakArray
of 2^20 slots each naming one live Array): 11.6 ms in the record's
`weakNs`, 11.1 ns a slot, in a debug build on the mini (a release build
not measured). The bound is therefore the weak holders' slot count times
that cost: a WeakArray of 16 777 215 slots adds about 186 ms (debug) to
every final mark; nothing in the kernel or the tools keeps a weak holder
of more than a few thousand slots.
22. `kernel.F11` (62cff96): `Fraction>>hash` is its `asFloat`'s (Fraction
and Float compare as Floats here, so that is the one consistent rule);
`FractionTest>>testAFractionHashesAsTheFloatItEquals`. 23. `interpreter.
F4` (428eb6b): `resend` refuses a frame with the discard or cascade marker
and checks R's fp against the verifier's traced depth at the send's start
(`rfp == sh + Frame.context + depth - n + 1`, the loader's rule), which
also catches a marked frame `terminateTo:` moved into place (it drops the
marker); `aResendFromAnInterruptsFrameIsRefused` (a waiting Process
interrupted for the debugger, whose `stopForDebugger` resends its
caller's send: refused, the Process waits again with its sp unchanged;
with both checks off by hand it resends and the saved sp grows by one).
24. `interpreter.F5` (bfed643): today a save drops a pending interrupt or
terminate request (they are in the host's record only, and `saveInStop`
wrote none of it); now the save is refused while any record has one
(`snapshotsRefusedPending`); `aSaveWaitsForPendingInterrupts`.

### The bar

- **Tests failing before.** Every new test was run on 8a8847d in a worktree
  (`failing-before.txt` of the hand-back). Failing there: items 1 (both
  tests, and the hand run above), 2 (the trap above), 3, 4, 6, 7 (killed by
  its 300 s bound, the reporting Process deadlocked at 0 % CPU), 8, 9 (the
  outer and pass tests), 10 (handles and the pragma index), 11, 12 (the
  test process died at `set height: inf`), 13, 14 (the released-then-
  terminated case, for the Semaphore and the Mutex), 15, 16 (422 s against
  0.14 s), 17, 18, 20, 21 (polls 0, the stretch the whole copy), 22, 23,
  24. Passing there, honestly: item 9's `retryUsing:` test, item 10's
  concurrent compiles (no entry lost in that run; the lock is by
  construction) and item 14's "terminated while waiting" (the old shape
  already gave nothing back there; the failing case is the signalled one).
  Not runnable there, being the fix's own instrumentation: item 5's
  `lateWrites` and item 19's `failAllocations`; the broken variants of item
  2 (`walksSeeBuilding`) and the by-hand switch-offs of items 14 and 23 stand
  for them.
- **`interpret`.** Identical instruction for instruction: the two aligned
  `-enable-testing` release builds of the A/B (8a8847d and 4598647), 1817
  lines each, differ after normalizing addresses to the function's start
  only in the low bits of the jump table's address (`add x26, x26, #0x74e`
  against `#0xb4e`, four places, the table's page offset). `just arc-check`
  passes on 4598647 ("OK: no retain or release on the checked paths; the
  dispatch loop is one jump table"; `dequeueLocked` 120 instructions,
  `waitSemaphore` 374, ARC 0).
- **The aligned A/B** against 8a8847d (`scripts/ab.sh`, 5 interleaved
  runs, checksums the same everywhere): 1 worker 0.997 to 1.006, 8 workers
  0.977 to 1.031 with overlapping ranges, cycle ratios 0.997 to 1.012,
  instruction ratios 0.999 to 1.001.

| kernel | 1 worker | 8 workers |
|---|--:|--:|
| alloc | 1.006 | 1.002 |
| arith | 1.001 | 1.023 |
| fib | 0.997 | 0.977 |
| ivars | 0.998 | 1.010 |
| sends | 1.001 | 1.006 |
| st-closures | 0.999 | 1.031 |
| st-ivars | 1.001 | 1.017 |
| st-sends | 0.997 | 0.993 |
| storeheavy | 0.997 | 1.010 |

- **`ExtremeIntegerTests`** gained primitive 38 over a 40 000-slot Array
  (past one polled chunk), 93 with an integer argument and 148 with
  integers for its path and text; the suite passes (93 and 148 take no
  integer as such: an integer is refused like any other non-Boolean,
  non-String argument).
- **The protocol fuzzer** on the changed reader: `just fuzz protocol 120`,
  "libFuzzer build: ok (Apple Swift version 6.4.2)", 360 063 runs in 121 s,
  no crash.
- **The round trip** (`scripts/canonical-tonel.sh --check`) clean before
  every kernel or tools commit (each was rewritten by the script first, then
  checked) and on 4598647.
- **`just check 8a8847d`** on the final code commit: below.

### Deviations

- Item 14 needed a VM change (a terminate after a completed wait is left
  for the Process's first poll), in `dequeueLocked` and `runSlice`.
- Item 9: the report's first example answers 2 under ANSI, not 20; the
  test separates the old and new behaviour with `* 100`.
- Item 12: the report's trap is not reachable through an NSView (frames
  are clamped to 2^45); the real trap was a non-finite value at `set`,
  fixed by refusing non-finite geometry.
- Item 21's weak pass is measured, not bounded.
- Item 23 checks the traced depth as well as the marker: `terminateTo:`
  drops a moved frame's marker, so the marker rule alone misses the
  restart path.
- Three test faults found by the first `just check` runs, each fixed in
  the tests and the run started again: the 1 MiB write to a connection
  the server closes raised SIGPIPE in the test process (`swift-test`,
  signal 13; the raw sockets set `SO_NOSIGPIPE`, 3dc41ae); the
  concurrent-writer test's reads were autoreleased into a pool never
  drained, and ThreadSanitizer's allocator ran out of chunks (`tsan`,
  `CHECK failed sanitizer_allocator_secondary.h:42`; a pool per read,
  b6e7be8); and under the sanitizer 20 connects at once overflowed the
  listen backlog of 16 (three reset by the kernel, never accepted, so
  `unpairedClosed` read 17) and `RegistryTest`'s 60 s wait ran out
  (connects paced to the accepts, `ProtocolServer.acceptedCount`;
  RegistryTest's bound 600 s and its work lighter: 480 handles, 8
  rebuilds read 100 times, 4 x 20 compiles; d59d0fc). The failures on
  8a8847d quoted above are of the heavier RegistryTest (1600 handles, 30
  rebuilds, 4 x 40 compiles).

### Not done

- The `EMFILE` accept path has no test (item 4); the client side of item 5
  has no test of its own; 154's put-back is tested only through 160's.
- A waiting Process loaded from an image has no recorded wait length; its
  debug stop is after the send as before (item 3).
- The UIEventLoop's timers and actions and the tools' class-side tables
  stay unsynchronized (main-affine UI state, item 10's table).
- The final mark's weak pass in a release build is not measured.
- The kernel report's further suggestion for item 7 (make the lock a Mutex):
  not done; the text is made outside the lock, which closes both the error
  and the nested-write deadlock.

### Open questions (decisions only)

1. `primitives.F7`: the host decides the client's project directory (the
   tools ask the host by a `project` op), a later follow-up; nothing built.
   Answered by the owner on 2026-11-10, as recommended.
2. `primitives.F2`'s limits: 8 unpaired connections, 4 KiB and 5 s before
   the session opens, as named; the phone's pairing flow sends one
   `session.open` line of about 100 bytes within a second, well inside
   them. Answered by the owner on 2026-11-10, as recommended.
3. `interpreter.F2`: a suspended waiting Process re-waits on proceed (its pc
   rewound to the wait send, the operand the Semaphore already in place);
   terminate keeps unlinking. Answered by the owner on 2026-11-10, as
   recommended.
4. New: should the final mark's weak pass leave the stop (a read barrier on
   weak slots that answers nil for an unmarked referent until the pass has
   run, with the sweep waiting for it)? Recommended: not now; the measured
   cost is proportional to weak slots, which no kernel table approaches.
5. New: `theServerServesTCPWithTheTokenRuleAndTheLimits` waits 120 s for
   a report on a global queue and ran out once under the sanitizer and
   twelve busy loops in this module's gate run (passing three reruns).
   Recommended: wait for it as long as the gate's own bound (the
   assertion unchanged), in part 2. Closed by the main session the
   same day with a fix instead of a longer wait (0110f70, "The
   pause-ended report" below): nothing waits on a global queue any
   more.

### `just check 8a8847d`

The fourth run, on d59d0fc (the code of the module's last code commit;
the three runs before it stopped at the test faults listed under
Deviations), the core tier, every gate, 13 216 s, swift.org 6.4.2:

    2026-11-10 13:12:47 d59d0fc check-tier core: 59 files from 8a8847d...HEAD (8a8847d...d59d0fc) and the working tree
    2026-11-10 13:13:10 d59d0fc end clean-build rc=0 23s
    2026-11-10 13:20:05 d59d0fc end swift-test rc=0 415s
    2026-11-10 13:28:19 d59d0fc end swift-test-load rc=0 494s
    2026-11-10 14:21:16 d59d0fc end tsan rc=0 3177s
    2026-11-10 15:26:37 d59d0fc end tsan-load rc=1 3921s
    2026-11-10 15:26:52 d59d0fc end ios-check rc=0 15s
    2026-11-10 15:27:11 d59d0fc end arc-check rc=0 19s
    2026-11-10 15:28:25 d59d0fc end golden rc=0 74s
    2026-11-10 15:30:06 d59d0fc end test-release rc=0 101s
    2026-11-10 15:30:27 d59d0fc end model-check rc=0 21s
    2026-11-10 15:31:39 d59d0fc end soak rc=0 72s
    2026-11-10 15:41:43 d59d0fc end fuzz-kasm rc=0 604s
    2026-11-10 15:51:47 d59d0fc end fuzz-snapshot rc=0 604s
    2026-11-10 16:01:58 d59d0fc end fuzz-syntax rc=0 611s
    2026-11-10 16:12:07 d59d0fc end fuzz-protocol rc=0 609s
    2026-11-10 16:14:11 d59d0fc end apps rc=0 124s
    2026-11-10 16:15:30 d59d0fc end kernel-test rc=0 79s
    2026-11-10 16:19:33 d59d0fc end new-check rc=0 243s
    2026-11-10 16:24:54 d59d0fc end ab rc=0 321s
    2026-11-10 16:38:41 d59d0fc end matrix-mac rc=0 827s
    2026-11-10 16:53:03 d59d0fc end matrix-iphone rc=0 862s
    2026-11-10 16:53:03 d59d0fc check-tier done core failed=1 13216s

Every gate passed but `tsan-load`, which failed one existing test of
module 9d, `PhoneTransportTests.theServerServesTCPWithTheTokenRuleAndThe
Limits`: its last check, that the listener's pause-ended report arrives
(dispatched to a global queue when the fake clock moves a minute on),
waited its 120 s and saw `[true]` for `[true, false]`; that report is
posted by `refusing()`, which this module did not change, and the same
check had already passed its `!server.isRefusing`, which is the call that
dispatches it. This is the wait AGENTS.md records ("a wait for a report
that runs on a global queue is a wait for the queue's thread, not a
bound"), now past 120 s with the suite 30 tests longer. Run again three
times under the sanitizer and twelve busy loops it passed every time
(34.6, 34.8 and 34.7 s). Not changed here; the test's bound is open question 5 (closed by
0110f70, below). ThreadSanitizer reported nothing in `tsan`
or `tsan-load`; `swift-test` and `tsan` ran 418 + 136 tests; the kernel
tests 240 of 240 (and 240 of 240 on the iPhone by `scripts/device.sh
tests`, thermal nominal); the fuzzers "libFuzzer build: ok" at 1.61,
0.82, 3.35 and 2.21 million runs (kasm, snapshot, syntax, protocol); the
gate's A/B 0.996 to 1.003 at 1 worker and 0.981 to 1.029 at 8, checksums
the same; the Mac matrix's bar: 156 rows, 0 launches failed, the ring
under `young=stw` 188 to 190 frames behind 9 fallbacks a launch and the
hog with the budget off 1193 by design, every other row 0; the iPhone's
(5 workers): 0 fallbacks, the ring under `young=stw` 2 to 5 frames behind
scavenges of 13.95 to 17.89 ms, the hog by design, every other row 0.

### The pause-ended report (0110f70, the main session)

The one failed gate was not the test's bound. `ProtocolServer.refusing()`
finds, under the server's lock, that a pause has run out, and sent the
report for it to `DispatchQueue.global()`; under ThreadSanitizer and
twelve busy loops no thread of that queue ran the block within the
test's 120 s. The report is now made by the caller that found the pause
over, after its unlock: `refusing(_:)` hands the report back through an
`inout` and `acceptLoop` and `isRefusing` call it once the lock is let
go. No report is made under the lock (a report that asks the server
anything would deadlock) and none waits for a queue. The test's
assertion and its 120 s are unchanged; the report is there when
`isRefusing` returns. Two files, `Sources/KajoDev/Server.swift` and a
comment in `Tests/KajoCompilerTests/PhoneTransportTests.swift`; nothing
under the core.

The gates on 0110f70: `just check d59d0fc` (the Swift tier, with the
protocol fuzzer its reader owes) and after it the two loaded test gates
of the core tier, run through the same `gates-lib.sh`, because the
failure was theirs:

    2026-11-10 17:02:38 0110f70 check-tier swift: 3 files from d59d0fc...HEAD (d59d0fc...0110f70) and the working tree
    2026-11-10 17:03:00 0110f70 end clean-build rc=0 22s
    2026-11-10 17:09:41 0110f70 end swift-test rc=0 401s
    2026-11-10 18:01:16 0110f70 end tsan rc=0 3095s
    2026-11-10 18:02:35 0110f70 end kernel-test rc=0 79s
    2026-11-10 18:04:37 0110f70 end apps rc=0 122s
    2026-11-10 18:08:40 0110f70 end new-check rc=0 243s
    2026-11-10 18:10:50 0110f70 end fuzz-protocol rc=0 130s
    2026-11-10 18:10:50 0110f70 check-tier done swift failed=0 4092s
    2026-11-10 18:10:51 0110f70 extra gates: swift-test-load tsan-load
    2026-11-10 18:19:04 0110f70 end swift-test-load rc=0 493s
    2026-11-10 19:28:04 0110f70 end tsan-load rc=0 4140s
    2026-11-10 19:28:04 0110f70 extra gates done failed=0

Every gate passed. `swift-test`, `swift-test-load`, `tsan` and
`tsan-load` each ran 418 + 136 tests with ThreadSanitizer reporting
nothing, and `theServerServesTCPWithTheTokenRuleAndTheLimits` passed in
all four; the kernel tests 240 of 240; both shells and the generated
app's products built with 0 warnings; the protocol fuzzer "libFuzzer
build: ok" at 366 795 runs in 121 s. With it every gate of the core tier
has passed on part 1's code: the fourth run above for all but
`tsan-load`, this one for `tsan-load` and again for the test gates.

## As built (part 2)

Built 2026-11-10 on master from 18e274f, one finding or one group per
commit, each named by its `<area>.F<n>` (or "note" and "part 1 not done").
The new Swift tests are in `Tests/KajoCompilerTests/ReviewFixesPart2Tests.swift`
(and `SavedProcessTests`, `ZeroingTests`, `ExtremeIntegerTests` where their
neighbours are), the kernel's beside their neighbours in `kernel/Tests/` and
`tools/Tests/`. Each was run on 18e274f in a worktree (the runnable Swift
ones copied into `Part2Before.swift`, the kernel ones into the worktree's
class files, adapted only where they call what the fix adds; said per
item); the outputs are in the hand-back's `failing-before.txt`.

### The two compilers agree, and refuse alike

**1. `kernel.F6`: recursion over untrusted or cyclic input** (48c2b11,
15517af, 6f72cbb). The Smalltalk compiler's `analyze:in:` and
`gen:in:on:value:` walk a message chain by a loop (`Compiler>>chainOf:`,
the bootstrap's `Compiler.chain` rule: a super send or an inlined send ends
a chain; the receiver first, then each send's arguments innermost first,
the order the recursion had, so the bytecodes are unchanged and
`CompilerTest` still agrees on every method). Code generation walks it by
the analysis's own mark (`chainOfAnalysed:`, a send the analysis inlined
ends it) rather than asking `inlinable:` again: with the second ask a
4000-send evaluate took 3.3 s in the debug kernel against 3.1 s on
18e274f; with the mark 3.15 s (found tracing the second gate run's
failure, below). `DevSession>>printOf:` prints through a new
kernel class `LimitedWriteStream` (Streams): at 4000 bytes its limit block
answers from `printOf:` with the text cut on a scalar boundary and `...`,
and its `print:` writes `...` for an object it is already printing (a set
of the objects being printed, kept as a stack), so a cyclic collection
answers a cut text and a collection of a million elements is never printed
whole (the discoverability doc's "not done" for `describe:`).
`DebugStop>>frameDetail:session:` describes through the same `printOf:`.
The net: `DevProtocol run:` answers from an `ensure:` block when its
Process is terminated (by anyone), and a reaper Process, started by `run:`
under the protocol's lock when a request is pending and none runs, looks
every 100 ms for a pending request whose Process has ended and answers it
(`the request's Process ended without a reply`): a VMError (a stack
overflow, memory) ends a Process without unwinding, so no `ensure:` runs
for it. The reaper ends when nothing is pending, so an idle image has no
such wake-up (the idle-cost lesson). Tests: `CompilerTest>>
testALongChainIsWalkedByALoop` (120 000 ` abs`: CompiledCode or a
CompileError; 120 000 overflowed on 18e274f and 60 000 did not, so the
test uses 120 000, about 24 s in the debug kernel tests), `DevelopmentTest>>
testACollectionThatHoldsItselfPrintsCut`, and `ReviewFixesPart2Protocol
Tests` (a request ended by a stack overflow answered; a request whose
Process another Process terminates answered; a chain of 20 000 sends over
the protocol a reply). On 18e274f:

    kernel testALongChainIsWalkedByALoop: kajo test: error: stackOverflow #= (receiver Symbol) in Collection>>[] at pc 4
    kernel testACollectionThatHoldsItselfPrintsCut: kajo test: error: stackOverflow #printString: (receiver SmallInteger) in Integer>>printString at pc 3
    ✘ Test aRequestEndedByAVMErrorIsAnswered() failed after 121.835 seconds with 1 issue.
    ✘ Test aRequestWhoseProcessIsTerminatedIsAnswered() failed after 123.338 seconds with 1 issue.

(the 20 000-send chain passes there: its depth is under the limit).

**2. `kernel.F7`: one identifier rule** (05d0f97). The predicate is
`IdentifierRule.classify` in KajoVM (`Sources/KajoVM/ObjectModel/
IdentifierRule.swift`): 1 for a letter (ASCII A-Z, a-z, `_`, or a scalar
the host's Unicode tables call alphabetic), 2 for a scalar that only
continues an identifier (an ASCII digit, or a non-ASCII scalar with a
numeric type that is not alphabetic), 0 otherwise and for any integer that
is no scalar. The bootstrap's scanner calls it in `Lexer.isLetter` and
`identifierRun` (`Sources/KajoCompiler/Syntax.swift`, the same function
moved, no second table); the kernel's `Scanner>>isLetterAt:` and the new
`isIdentifierPartAt:` keep the ASCII fast path and ask primitive 171,
`Scanner class>>identifierClassOf:`, for any scalar above 127. 171 takes a
SmallInteger and fails for anything else; it is in `ExtremeIntegerTests`.
Tests: `bothCompilersFollowOneIdentifierRule` (U+00D7, U+00B7, U+2192,
U+1F600, U+00A0, U+0301, U+0663 and two letters, at the start, inside and
at the end of a temp, a selector and a Symbol: both compilers agree) and
`CompilerTest>>testIdentifiersFollowTheBootstrapsRule`, which fails on
18e274f ("Denial failed": the kernel accepted `×x`). The Swift test needs
item 2's comparison probe and cannot run there.

The probe, used by items 2, 5, 6 and 7: `KernelCompilerProbe` (KajoVM,
`Loader/`) holds a kernel image and an interpreter of no VM, as the
make-and-run mode does; for a source it builds the bootstrap's
`AssembledMethod` as a CompiledCode (`Image.codeObject`) and runs
`Compiler class>>compare:in:with:`, which compiles with the kernel's
compiler, makes the method (the VM's verifier, as the bootstrap's
assembler runs it), and compares the two CompiledCodes in their plain form
(`CompiledCode>>sameCodeAs:`: selector, bytecodes, header, literals, block
methods the same way). Both refusing agrees; any other error is a
difference. `CompilerAgreement` (KajoCompiler) compiles in
`MakeFuzzSample` (instance variables a and b, as the fuzz context's).

**3. `kernel.F8`: a `[` in a pattern comment** (86df515). Both readers
(`Tonel.swift`, `TonelReader>>readMethodInto:`) skip a comment while they
look for the body's `[` (a pattern holds no string); the writer and the
canonical form are unchanged and no file was rewritten. A comment before
the pattern was never the report's problem: both readers' `space` skips
it as blank. Tests: `TonelTest>>testACommentInAPatternKeepsItsBrackets`
(read, compiled, written back byte for byte) and `aCommentInAPatternKeeps
ItsBrackets` (the bootstrap reader on the new syntax seed
`pattern-comment.class.st`). On 18e274f:

    TonelTest>>testACommentInAPatternKeepsItsBrackets: errored, "line 11: unterminated comment"
    ✘ Test aCommentInAPatternKeepsItsBrackets() recorded an issue: Caught error: pattern-comment.class.st:13: expected >> after helper

**4. `kernel.F9`: a redefinition against the subtree's names** (de40db2).
The redefine specification gains a fifth part: for every class at or
below a class whose shape or pool changes, `{class. every instance
variable name. every class-side instance variable name}` as they will be
(`ClassBuilder class>>namesAfter:own:ownMeta:`, from the kernel's
definitions). Primitive 146 (`namesProblemAfter`, `LiveClasses.swift`)
refuses when a class at or below a changed one is missing (obsolete
classes excepted), checks each list's length against the slots the class
will have, then runs `ClassRules.namesProblem` for each given class with
its own names (past its superclass's slots), its pool after the change and
the pools of its superclasses after the change, before anything changes;
the reason is the usual String and `ClassBuilder` signals it as a
ClassDefinitionError. A specification with no shape and no pool only
checks the classes given (`ClassBuilder class>>namesProblemIn:`). Without
shapes or pools nothing is required, so a methods-only redefinition is as
before. The raw specifications in `LiveClassTests` and
`RedefineOrderTests` gained their names. Tests: `LiveClassTest>>
testARedefinitionThatTheSubclassesNamesClashWithIsRefused` (a class
variable a subclass declares, an instance variable shadowing the class's
own class variable, a class variable a subclass's instance variable
shadows: each refused, nothing changed, the names rule holds after; an
unrelated redefinition accepted), and `ClassFuzzTest>>
testSeededReshapesAreRefusedOrAccepted`, whose specifications carry the
names (the class side's too), every twentieth one with broken names (a
name twice, the names missing, one name too many), and which after every
accepted redefinition runs the build's names rule over every class
through an empty change (500 mutations: 396 refused, 104 accepted, every
check nil). On 18e274f the clash test fails ("Expected ClassDefinitionError
to be signaled"; its `namesProblemIn:` assertions removed there).

**5. `kernel.F14`: the generator refuses what the assembler refuses**
(2654790). `BytecodeGenerator>>assembleWithExtraLiterals:` refuses, with a
CompileError naming the limit, an operand past 65535, a second operand
(argc, copied count, vector temp) past 255, a jump past an Int16, more
than `BytecodeGenerator maxMethodBytes` (32 760) bytes and more than
`maxLiterals` (4095) literals, the source map counted: the assembler's
limits (`Assembler.swift`). The make primitive refuses a bytecode
ByteArray longer than `LoaderLimits.maxMethodBytes` before its verifier
reads anything (`CodeReader.read`, `LiveMethods.swift`). Tests:
`bothCompilersRefuseAtEveryEncodingLimit` (a keyword send of 255 and 256
arguments, a block copying 255 and 256 values, 32 760 and 32 763 bytes,
4095 and 4096 literals: the bootstrap accepts each at the limit and
refuses past it, and the compilers agree on all eight; under
ThreadSanitizer the first four only, the big pairs taking minutes in the
Smalltalk compiler there) and `CompilerTest>>testEncodingLimitsAreCompile
Errors` (256 arguments a CompileError naming 255; the make primitive
refusing 32 761 bytes "more than 32760 bytes"; a CompiledCode with
-2^62, 2^62 - 1 or -1 in each of its six integer fields refused, never a
trap). On 18e274f the kernel test errors ("index 516 out of bounds", the
generic Error the report named).

**6. `kernel.F15`: the smaller disagreements and the corpus** (2654790).
`Compiler>>isIntegerLiteral:` and the `to:by:do:` step test ask `class ==
SmallInteger` (the bootstrap's `.integer`); `<primitive:>` takes a
SmallInteger 1...255, once ("primitive: takes 1...255", "two
primitives"). The corpus, `Tests/KajoCompilerTests/Fixtures/compiler-corpus/
corpus.txt`, holds 154 methods: literals at the SmallInteger boundary and
past it, radixes, every inlining decision with SmallInteger and
LargeInteger steps and limits, the primitive pragma's rules, names and
scoping, nesting 31, 32 and 33 of blocks, parentheses, braces, literal
arrays and assignments, 254 to 257 temps, blocks of 15, 16, 255 and 256
arguments, and malformed sources; `bothCompilersAgreeOnTheCorpus`
compares them. It found one disagreement, the bootstrap's: the assembler
accepted a method of 257 temps (with its argument) and a block of 256
arguments that the heap verifier, so the make primitive, refuses ("a
header value out of range": `argc + temps <= maxTemps`, a block's temps
counting its copied values and closure word); the kasm parser checked it,
the compiler's `AsmMethod` path did not. `assemble` now refuses both.
Test: `CompilerTest>>testIntegersAndPrimitivesAsTheBootstrapDecides`,
failing on 18e274f ("Assertion failed": the LargeInteger step inlined).

**7. `kernel.F16`: the kernel's compiler is fuzzed** (0753e83).
`KAJO_FUZZ_KERNEL=<kernel dir>` puts `fuzz-syntax` in its kernel mode
(`scripts/fuzz.sh syntax-kernel <seconds>`): the fuzz thread (512 KB, the
smallest stack the bootstrap compiler runs on) builds a kernel image from
the directory at its first input and keeps a probe; every method source,
and every instance-side method of a Tonel input (at most 16), is compared
(`KernelModeFuzz.run`), and a disagreement is a fatal error whose message
is the source and the difference, so libFuzzer keeps the input. The
Smalltalk compiler runs on a stack of `VMConfig.maxStackWords` words, a
Process's limit, so a VMError there is a disagreement. Runs:

| run | seconds | executions | disagreements |
|---|--:|--:|---|
| first, the working tree after 2654790 | 60 (stopped at its crash) | 38 | `crash-2ca723e8…`, then on replay `crash-74e6ac94…` |
| second, after the probe's UTF-8 rule | 300 (stopped) | 405 | `crash-34771487…` |
| third, after the bootstrap's UTF-8 check | 400 | 40 960 | none |
| the bar's run, on c84e171 (the final code) | 601 | 47 082 | none |

All with "libFuzzer build: ok (Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))",
about 80 to 100 inputs a second (each one compiles in Smalltalk in an
ASan build).

The disagreements and their fate:
- `crash-2ca723e8…` (a `replaceFrom:to:with:startingAt:` source with
  bytes that are not UTF-8 in its `<primitive:` pragma) and `crash-74e6ac94…`
  (a mutated Integer file, `isPrime`): the kernel's compiler overflowed
  its stack on a String that is not UTF-8. No path hands the kernel such a
  String (every String in the image is valid UTF-8; the protocol's reader
  validates), so the probe now gives the kernel valid UTF-8 only and
  counts bytes that are not as the bootstrap's alone (agreeing when the
  bootstrap refuses them).
- `crash-34771487…` (CompilerTest's `knownDifferences` with a bit flipped
  in its comment): the bootstrap accepted a method whose comment is not
  UTF-8 (the scanner validates the scalars it reads, not a comment's
  bytes), so its recorded source would be an invalid String in the image.
  Fixed: `parseMethod` validates the whole source first ("invalid UTF-8").
The inputs are in the hand-back's `fuzz-kernel-findings/`.

**8. `kernel.F17`: documented** (d9a2c8e). `docs/modules/kernel-live.md`
says beside the per-iteration rule that an uncaptured (or captured but
never assigned) temp of an inlined loop body keeps its value across
passes in both compilers, with Pharo's behaviour (Opal nils every such
temp each pass) and why Kajo keeps it (open question 3). Pinned by
`BlockClosureTest>>testAnUncapturedLoopTempKeepsItsValue` (#(1 2 3), and
#(1 1 1) with an unrelated `[t] value`), which both compilers pass (the
kernel's by `CompilerTest`'s comparison of every method) and which passes
on 18e274f by design; the corpus holds both forms.

### The tools and the scripts

**9. `tools.F3`: evaluate the selection once** (da01f76). `DevTools
class>>instancesOf:with:` and `pointersTo:with:` evaluate the selection
once where the workspace evaluates, then ask about the object it answered
through a workspace model whose receiver is its handle (`self
instanceCount`, `self allInstances: 1000`, `self pointerCount`, `self
pointersTo: 1000`); an answer with no handle (nil, a Boolean, a small
Integer, a Character) is named by its printString, which evaluates to it.
The title is the first evaluation's printString. The Inspector's pointers
to a slot's value go through the same path. From that evaluation on the
session's handle table holds the object, so it is among the holders, as
it already was for an inspected object. Tests: `DiscoverabilityTest>>
testTheSelectionIsEvaluatedOnce` (one evaluation of the selection per
action), the two existing tests' request sequences and
`InspectorModelTest>>testObjectsPointingToTheObjectAndToASlotsValue`
updated. On 18e274f: "Expected 2 but was 0" (the selection was sent in
parentheses with a message, never alone, three times).

**10. `tools.F4`: fixtures and renames** (8f7b584). `check-tier.sh`
classifies `Tests/*` as swift before `*.md`, and both diffs run with
`--no-renames`; `KAJO_CHECK_REPO` names the repository whose diff decides
(the test's scratch repository). `check-tier-test.sh` gains three fixture
cases and a scratch repository whose commit, then working tree, moves
`Sources/KajoVM/Marking/X.swift` to `Sources/KajoVM/Shell/` (core both
times). On 18e274f the fixtures were "tier: none, nothing owed: docs only"
and the committed rename "tier: swift".

**11. `tools.F5`: a matrix gate fails when any step fails** (200147c,
979a0aa). The
Mac matrix gate runs the matrix, the report and the bar, each failing the
gate (`rc`), the later still running; `device-rows.sh` the same;
`shell-matrix.sh` ends with `exit 0`, so its status is the script dying;
`shell-report.py --bar` over a directory with no rows prints so and exits
1. `check-tier-test.sh` runs `--bar` over a fixture with a row (0) and one
without (1), and the gate's command with the matrix step failing (non-zero;
`GL_MAC_SHELL` and `GL_SHELL_MATRIX` stand in for the scripts). On
18e274f `--bar` over no rows exited 0. The first version kept the steps'
status in a variable named `status`, which is zsh's read-only `$?`:
`device-rows.sh` died at "read-only variable: status" before its first
row in the second gate run (and the gate failed, as this item wants); the
variable is `steps_rc` (979a0aa). Nothing ran `device-rows.sh` before
the gate: a script change's first run was its gate (the lesson below).

**12. `tools.F6`: the small items**, each its own commit.
- The `sudo` line (d612458): `CommandLineTool.shellQuoted` quotes the
  directory, the CLI and the link (`'\''` for a quote). Test
  `theSudoLineQuotesItsPaths` runs the line through `sh` with `sudo` a
  printer under `Joni's Apps/` and a `no such bin` directory; on 18e274f
  `/bin/sh: syntax error: unexpected end of file`. The line is never run.
- Two launches (ace0819): `CheckoutInstaller.install` looks for the marker
  again after its copy (a complete folder is `.present`, never moved
  aside), takes a final rename that loses to a complete copy as that copy,
  and gives each attempt its own partial folder. Test
  `concurrentInstallsLeaveOneCompleteCheckout` (eight at once, ten
  rounds, under a temporary directory, never the real Application
  Support); on 18e274f 19 issues (failed installs, no marker left).
- The `kajo` target (85174f8) builds with `.strictMemorySafety()`. A clean
  build of the target flagged three sites in `Sources/kajo/main.swift`: two
  `String(format:)` calls (C varargs), now formatted without them
  (`oneDecimal`, a rounded Int), and `fflush(stdout)` (C's global
  `stdout`), marked `unsafe`, the target's one unsafe construct.
- `new-check.sh` (f3efbef): `symbols()` counts KajoVM's symbols last and
  the Release checks require some, so their zeros mean absent, not
  stripped (macos-release `KajoVM=5761`, ios-release `5743`).
- `dist.sh` (0325f7c): each slice and module's compile line must hold
  `-O`, `-whole-module-optimization` and `-strict-memory-safety` and none
  of `-Onone`, `-enable-testing` or `-g`, and a missing line fails. Run by
  `dist.sh checkout` in `just new-check`: all three slices passed (macOS
  34 s, iOS 33 s, simulator 33 s). No signed `dist` was run.
- `Host.current().localizedName`: traced with the launch trace in five
  Debug launches of a generated Sample on the mini (`kajo-launch-report
  kajo-frames=1`): `pairing-screen` to `device-name` took 0.4 to 0.5 ms
  (614.3 to 614.7, 249.9 to 250.4, 227.8 to 228.3, 247.0 to 247.5, 257.8
  to 258.2 ms after the process started), after the first frame. Not
  moved: it does not wait here. (On a network whose name lookups hang it
  could, as `hostName` did on iOS; `SCDynamicStoreCopyComputerName` reads
  the name with no lookup and is the change to make if a trace ever shows
  a wait.)

**13. `primitives.F8`: the client's reader** (0b4e4cb). `ProtocolClient`
reads lines up to `lineLimit` (64 MiB, the image's client's and the
server's bound; an `init` argument), discards the rest of a longer line,
counts it, and a request waiting answers an error instead of waiting out
its timeout (the long line may have been its reply). Its descriptor is
closed by whichever of the reader and `close()` ends second, once
(`descriptorCloses`), never after a bounded wait while the reader may
still read it; `write` refuses after `close`. Tests: `aLineThatPassesThe
ClientsLimitIsAnAnswer` (64 MiB + 4 KiB with no newline: answered in
0.37 s; on 18e274f it waited its 120 s), `theClientsDescriptorIsClosed
OnceByWhoeverEndsLast` (a `close` during a 1.5 s event callback returns at
once, the descriptor is not closed under the callback, then closed once;
the counter is the fix's, not runnable there).

### The reports' notes

**14. The token store** (0f1f172). `PairingTokenStore.renew` throws
`StoreError` unless the token was written whole, synced, closed and
renamed into place (the temporary is removed on any failure);
`loadReporting` (and `load`) keep a token only from a regular file with no
mode bit beyond 0600, replace any other (a wider mode, a link in its
place: open question 2) with a new token, and serve an in-memory token for
the launch when none can be written, the problem on the console without
the token (`serving token_kept=0 problem=...`). New token whose `renew`
fails keeps the old token and says why on the pairing screen and the
console. Test `theTokenStoreKeepsOnlyWhatItWroteAndRefusesAWideMode`
(every comparison a Bool, no token printed: a directory made read-only
refuses the renew and the old token stands; mode 0644 replaced and
written 0600; a link replaced by a regular file, its target untouched).
On 18e274f (its renew assertion adapted to the non-throwing renew): 5
issues.

**15. The reply's timestamp** (c79361a). `ClientHost.run` takes the time
as the line arrives and stamps its events with it, before
`ProjectWriter.apply`'s writes; a write's failure is still timed when it
happened. Test `aReplysLineIsTimedWhenItWasRead` (a reply whose file
write is refused: its line's time is not after the failure's); on
18e274f "Expectation failed: line.timeNs <= failure.timeNs".

**16. `ShellBridge.post` against a re-registration** (5b5ef62). The path
exists. `post` read the event Semaphore under the bridge's lock, let it
go, and pushed an external signal naming the Semaphore with no root of
its own (`handle: nil`). Meanwhile primitive 153 could register a new
Semaphore and then free the old one's pending root (`unregisterPending`
after `register` returns); the old Semaphore, now held by nothing, could
be swept by a collection before a worker drained the signal, and its
entry taken by a new Semaphore; `drainExternal` checks only that the
entry is a used Semaphore, so it signalled the new one: an excess signal,
which on a Mutex's Semaphore lets two Processes in. (The new registration
owes its own signal for the queued event, so the stale one is pure
excess.) Closed: `post`, `putBack`, `postRequest` and `putBackRequest`
take a pending root for the Semaphore under the bridge's lock, where it is
still rooted by the registration (the old root is freed only after
`register` took that lock), and the signal carries the handle the drain
releases (`VMRef.rootPending`); a full table signals as before. Test
`aQueuedShellSignalRootsItsSemaphoreUntilItIsDrained` (one worker driven
by turns: a posted event's signal adds one pending root until a turn
drains it); on 18e274f "the queued signal holds no root".

**17. Recorded, not built.** A spoofed Bonjour name receives the token
(plain TCP now, PSK-TLS later, the owner's decision of 9d); ten wrong
tokens a minute pause the listener (by design).

### Part 1's "not done"

**18. Tests owed** (b96a1a0). `ProtocolServer.injectAcceptFailures(n)`
makes the accept loop's next n `accept` calls fail with EMFILE without
calling it: `theAcceptLoopWaitsOutInjectedFailures` (three counted,
waited out, the next connection served).
`ClientConnection.lateWriteCount` counts write blocks that run after its
descriptor is closed: `noClientWriteRunsAfterItsConnectionIsReleased`
(eight senders while `release` comes, 20 rounds, 0, and a send after it
refused). `anEventTheImageCannotAllocateIsNotLost` (primitive 154's
put-back on its own: the take fails as a full heap's, the next answers the
event); it passes on 18e274f, part 1 having made the fix.

**19. A loaded waiter's wait length** (d6ed7f7). `installSavedProcesses`
gives a Process saved while waiting the length of the instruction that
ends at its saved pc when it is a send of no argument (its top frame's
method decoded with `verifyHeapMethod`, which the loader already ran on
it against the depth at that pc), as `waitSemaphore` records it for a
live one; so its debug stop rewinds to the `wait` and proceeding waits
again. The length is found at load from the instruction itself; no image
format change. Test `aLoadedWaiterKnowsTheLengthOfItsWaitSend` (the three
waiters of `shapesImage`, each after a three-byte `send wait 0`, then
released); it reads the record through a new accessor and cannot run on
18e274f, where no loaded record had a length.

**20. The weak pass in a release build** (6a2a900).
`theWeakPassIsMeasuredPerSlot` takes its slot counts from
`KAJO_WEAK_SLOTS`; `swift test -c release -Xswiftc -enable-testing`, three
runs on the mini:

| slots | weak pass ms | ns a slot | final pause ms |
|--:|--:|--:|--:|
| 2^20 | 0.794 to 0.804 | 0.757 to 0.767 | 0.814 to 0.834 |
| 2^24 - 1 | 12.264 to 12.293 | 0.731 to 0.733 | 12.285 to 12.317 |

Against part 1's debug 11.6 ms for 2^20 (11.1 ns a slot), a release build
is 15 times faster; the bound part 1 stated becomes about 12.3 ms for the
largest WeakArray, a frame and a half at 120 Hz, and under a millisecond
for 2^20 slots.

### The bar

- **Tests failing before.** Every new test was run on 18e274f in a
  worktree (`failing-before.txt` of the hand-back). Failing there: item 1
  (both kernel tests end the test run in a stack overflow; the VMError and
  terminate protocol tests waited their 120 s), 2 (the kernel test), 3
  (both), 4, 5 (the kernel test: "index 516 out of bounds"), 6, 9, 10 (the
  fixtures "nothing owed: docs only", the rename "tier: swift"), 11
  (`--bar` over no rows exited 0), 12 (the `sudo` line, the concurrent
  installs), 13 (the long line waited 120 s), 14, 15, 16. Passing there,
  honestly: item 8's test (documentation, by design), the 20 000-send
  protocol chain (under the old stack limit; the kernel test at 120 000
  fails), 18's put-back test (part 1's fix). Not runnable there, being the
  fix's own instrumentation or needing the probe: the three agreement tests
  (the kernel tests stand for them), 13's descriptor counter, 18's
  injection and late-write counter, 19's accessor, the changed reshape
  mutation test (its fifth part), and the matrix gate's command (on
  18e274f it would build and run the real matrix; the `--bar` case stands
  for it).
- **The two compilers** agree on every method of the image (`CompilerTest>>
  testEveryMethodCompilesAsTheBootstrapDid` in the kernel tests, 248 of 248
  headless and on the iPhone), on the corpus (154 methods, none
  disagreeing after the assembler's header rule) and under the kernel fuzz
  mode's 600 s (above); every disagreement found is fixed (three inputs,
  two causes, listed under item 7, and the corpus's one).
- **`interpret`** is identical instruction for instruction: the two
  aligned `-enable-testing` release builds of the A/B (18e274f and
  c84e171), 1819 lines each, differ after normalizing addresses to the
  function's start only in the jump table's page and low bits (`adrp x26,
  472/471/470` and `add x26, x26, #0xa4e` against `479/477` and
  `#0x1ee`, four places; `interpret.diff`). `just arc-check` passes on
  c84e171 ("OK: no retain or release on the checked paths; the dispatch
  loop is one jump table").
- **The aligned A/B** against 18e274f (`scripts/ab.sh`, 5 interleaved runs,
  checksums the same everywhere): 1 worker 0.997 to 1.011, 8 workers
  0.957 to 1.029 with overlapping ranges (the usual 8-worker spread),
  cycle ratios 0.988 to 1.013, instruction ratios 0.999 to 1.001.

| kernel | 1 worker | 8 workers |
|---|--:|--:|
| alloc | 1.004 | 1.016 |
| arith | 0.997 | 0.979 |
| fib | 1.003 | 1.026 |
| ivars | 0.999 | 0.957 |
| sends | 1.000 | 1.029 |
| st-closures | 1.004 | 0.957 |
| st-ivars | 1.001 | 1.015 |
| st-sends | 1.011 | 1.016 |
| storeheavy | 1.001 | 0.961 |

  `st-sends` at 1 worker (1.011, ranges 1388 to 1407 against 1396 to
  1409, instructions 1.000) runs a Smalltalk kernel built from the changed
  kernel; the dispatch is the same.
- **`ExtremeIntegerTests`** gained primitive 171 (a SmallInteger past the
  last scalar and the four extremes answer 0); the make primitive takes a
  CompiledCode, not an integer: its integer fields at -2^62, 2^62 - 1 and
  -1, each refused, are in `CompilerTest>>testEncodingLimitsAreCompileErrors`.
- **The round trip** (`scripts/canonical-tonel.sh --check`) was clean
  before every kernel or tools commit (each rewritten by the script first,
  then checked) and on c84e171.
- **`scripts/check-tier-test.sh`**: 44 checks, ok (it was 36 before part
  1's tests and this part's eight). The perf report's fixture test
  (`PerfReportTests`) passes in `swift test`.
- **Before the gates**: a full debug `swift test` (419 + 153 tests: one
  failure, item 16's first test, whose count a background worker's drain
  could beat in the full suite; rewritten to count on a VM no worker
  drains, f8d06ac, failing against 18e274f's bridge), the kernel tests
  248 of 248 (126 s headless, the 120 000-send chain about 24 s of it),
  the tools' tests touched, and every new test once under
  `swift test --sanitize=thread` with twelve busy loops: 0 reports, one
  failure of a new test, `theClientsDescriptorIsClosedOnceByWhoeverEndsLast`
  (the target's event reached the client before its callback was set; the
  target now sends it after the client's first line, c84e171, and the
  test passed loaded under the sanitizer). The kernel tests on the iPhone
  13 Pro (`scripts/device.sh tests`): 248 of 248 in 6.9 s, thermal nominal.
- **`just check 18e274f`** on the final code (06e74a6): every gate passed,
  below.

### `just check 18e274f`

The third run, on 06e74a6 (the final code: everything after it is this
doc), the core tier, every gate, 15 458 s, swift.org 6.4.2:

    2026-11-11 03:36:22 06e74a6 check-tier core: 63 files from 18e274f...HEAD (18e274f...06e74a6) and the working tree
    2026-11-11 03:36:43 06e74a6 end clean-build rc=0 21s
    2026-11-11 03:47:01 06e74a6 end swift-test rc=0 618s
    2026-11-11 03:59:31 06e74a6 end swift-test-load rc=0 750s
    2026-11-11 05:06:51 06e74a6 end tsan rc=0 4040s
    2026-11-11 06:29:31 06e74a6 end tsan-load rc=0 4960s
    2026-11-11 06:29:46 06e74a6 end ios-check rc=0 15s
    2026-11-11 06:29:51 06e74a6 end arc-check rc=0 5s
    2026-11-11 06:31:01 06e74a6 end golden rc=0 70s
    2026-11-11 06:32:00 06e74a6 end test-release rc=0 59s
    2026-11-11 06:32:21 06e74a6 end model-check rc=0 21s
    2026-11-11 06:33:32 06e74a6 end soak rc=0 71s
    2026-11-11 06:43:35 06e74a6 end fuzz-kasm rc=0 603s
    2026-11-11 06:53:38 06e74a6 end fuzz-snapshot rc=0 603s
    2026-11-11 07:03:41 06e74a6 end fuzz-syntax rc=0 603s
    2026-11-11 07:13:44 06e74a6 end fuzz-protocol rc=0 603s
    2026-11-11 07:15:43 06e74a6 end apps rc=0 119s
    2026-11-11 07:17:30 06e74a6 end kernel-test rc=0 107s
    2026-11-11 07:21:37 06e74a6 end new-check rc=0 247s
    2026-11-11 07:26:59 06e74a6 end ab rc=0 322s
    2026-11-11 07:39:57 06e74a6 end matrix-mac rc=0 778s
    2026-11-11 07:54:00 06e74a6 end matrix-iphone rc=0 843s
    2026-11-11 07:54:00 06e74a6 check-tier done core failed=0 15458s

`swift-test`, `swift-test-load`, `tsan` and `tsan-load` each ran 419 + 153
tests, ThreadSanitizer reporting nothing; the kernel tests 248 of 248; the
fuzzers "libFuzzer build: ok" at 2.22, 3.14, 0.87 and 1.81 million runs
(kasm, snapshot, syntax, protocol); the gate's A/B 0.996 to 1.008 at 1
worker and 0.954 to 1.059 at 8 (instruction ratios 0.999 to 1.002,
checksums the same); the Mac matrix's bar: 156 rows, 0 launches failed,
0 checksums wrong, the warm-up 0 of 1200, the ring under `young=stw` 164,
189 and 220 frames behind 8 to 10 soft-limit fallbacks whose compacting
full collections took 201 to 212 ms, the hog with the budget off 1192 to
1193 by design, every other row 0; the iPhone's (5 workers; 117 launches
at thermal nominal, 109 fair, 45 serious): 0 fallbacks, the ring under
`young=stw` 1 and 2 frames behind scavenges of 14.0 and 16.1 ms, the hog by
design, every other row 0.

Two runs before it stopped on this part's own faults, each fixed and the
run started again:
- The first, on 534ec98, failed `tsan`: `noClientWriteRunsAfterIts
  ConnectionIsReleased`'s eight senders on `DispatchQueue.global()` did
  not run within 60 s in four rounds under the full sanitized suite (the
  queue's threads were taken; AGENTS.md's "a wait for a report that runs
  on a global queue"); they are Threads now (ea58e5c). Stopped after
  `tsan`.
- The second, on ea58e5c, failed `tsan-load` and `matrix-iphone`.
  `matrix-iphone`: item 11's `status` variable, read-only in zsh (979a0aa,
  above). `tsan-load`: part 1's `connectionsWithoutASessionAreBounded`, its
  session's 4000-send `evaluate` past eval's 300 s under the sanitizer and
  twelve busy loops (the whole test took 247 and 268 s unloaded under the
  sanitizer in the two runs). Traced: compiling those 4000 sends in the
  debug kernel took 3.3 s against 3.1 s on 18e274f, item 1's code
  generation asking `inlinable:` per send again; with the analysis's mark
  3.15 s (6f72cbb); and the test waits 1800 s under the sanitizer for that
  one reply, the assertion unchanged (06e74a6). Every other gate of that
  run passed (`swift-test`, `swift-test-load`, `tsan`, the fuzzers, `apps`,
  `kernel-test`, `new-check`, `ab`, `matrix-mac`).

The A/B and `interpret` diff of the bar above were made on c84e171 (the
code of ea58e5c and 06e74a6 but for two test files and the kernel
compiler's chain walk, which `interpret` does not see); the gate's A/B on
06e74a6 agrees. The kernel fuzz mode's 600 s ran on c84e171 (47 082
runs) and again on 06e74a6 (45 163 runs, no disagreement).


### Deviations

- Item 2's test of both compilers and items 5 to 7 rest on a comparison
  probe in KajoVM (`Loader/KernelCompilerProbe.swift`, with `Image`'s
  `allocateBytes` made internal and a `classNames` accessor): a VM-side
  addition the brief did not name, test and fuzz support only (no
  primitive, no path a program reaches).
- Item 6's corpus found a bug in the bootstrap's assembler (257 temps, a
  256-argument block), fixed in `Assembler.swift` (`Loader/`, core): the
  heap verifier was the reference there, not the bootstrap.
- Item 7's runs found the bootstrap accepting a comment that is not UTF-8;
  `parseMethod` now validates the whole source.
- Item 4's VM change is a fifth part of the redefine specification (the
  names, which the VM does not hold); it is required whenever shapes or
  pools change, so every raw specification in the tests gained it.
- Item 12's installer fix also gives each attempt its own partial folder
  (the tests' concurrent attempts share a process identifier).
- Item 16's path existed, so the four signal sites of `ShellBridge` (`post`,
  `putBack`, `postRequest`, `putBackRequest`) root their Semaphore, with
  `VMRef.rootPending` added in `Processes/External.swift`.
- Item 18 added a test injection (`ProtocolServer.injectAcceptFailures`)
  and a counter (`ClientConnection.lateWriteCount`) outside the core.
- Item 19 added a test accessor `VM.waitSendLength(of:)`.
- `localizedName` was traced and not moved (0.4 to 0.5 ms after the first
  frame); the brief allowed either.
- A script change's first run was its gate: `device-rows.sh` was not run
  after item 11's change and died in the gate on zsh's read-only
  `status`. A changed gate script is run once on its own before the gate
  run (a lesson for AGENTS.md, the main session's to write).

### Not done

- The kernel fuzz mode compiles in one class (`MakeFuzzSample`, ivars a
  and b) on the instance side; class-side methods of a Tonel input and
  class variables are not compared.
- A String that is not UTF-8 handed to the kernel's compiler by a program
  (not by any path the system has) still overflows its stack; the probe
  does not feed it one.
- The reaper answers a request ended by a VMError within about 100 ms
  but cannot say which VMError (the host's log has it).
- `printOf:`'s cycle guard is its stream's `print:`; a `printOn:` that
  writes an element's `printString` (a fresh, unbounded stream) instead of
  `print:`ing it bypasses the guard and the limit for that element.
- The weak pass is measured, not bounded (part 1's open question 4
  stands).
- The iPad rows.

### Open questions (decisions only)

1. `kernel.F7`: identifiers follow the bootstrap's rule (Unicode
   alphabetic, the host's tables, through primitive 171), as recommended.
2. Note 14: a token file with a mode wider than 0600 (or a link in its
   place) is replaced by a new token, as recommended (pairing is
   repeated once).
3. `kernel.F17`: the loop body's uncaptured temps are documented, not
   nilled, as recommended.
4. New: should the reaper answer a VMError-ended request with the
   VMError's kind (a primitive that reads the host's error record by
   Process id)? Recommended: not now; the host's log has it and the reply
   already ends the wait.

