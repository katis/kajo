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

## Part 2 (the next agent; not this one)

`kernel.F6` (recursion bounds in `analyze:`/`gen:` and `printOf:`),
`kernel.F7` (identifiers above 127: the Smalltalk scanner follows the
bootstrap's rule), `kernel.F8` (a `[` in a pattern comment: the writer
escapes or refuses, both readers agree), `kernel.F9` (redefinition against
subclasses' class variables and ivar/class-variable clashes in `ClassRules`),
`kernel.F14` and `F15` (the Smalltalk generator refuses what the assembler
refuses; the `<primitive:>` range), `kernel.F16` (the Smalltalk compiler
fuzzed through the make primitive), `kernel.F17` (document), `tools.F3`
(evaluate the selection once), `tools.F4` and `F5` (`check-tier.sh`:
`--no-renames`, fixtures' `.md` owe the swift tier; the matrix gate's
status from every step), `tools.F6`, `primitives.F8`, the notes.
